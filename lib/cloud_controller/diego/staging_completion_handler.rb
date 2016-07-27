module VCAP::CloudController
  module Diego
    class StagingCompletionHandler
      DEFAULT_STAGING_ERROR = 'StagingError'.freeze

      attr_reader :droplet

      def initialize(droplet, runners=CloudController::DependencyLocator.instance.runners)
        @droplet       = droplet
        @runners       = runners
      end

      def logger_prefix
        raise NotImplementedError.new('implement this in the inherited class')
      end

      def logger
        @logger ||= Steno.logger('cc.stager')
      end

      def staging_complete(payload, with_start=false)
        logger.info(logger_prefix + 'finished', response: payload)

        if payload[:error]
          handle_failure(payload)
        else
          handle_success(payload, with_start)
        end
      end

      def self.success_parser
        @staging_response_schema ||= Membrane::SchemaParser.parse(&schema)
      end

      private

      def handle_failure(payload)
        begin
          error_parser.validate(payload)
        rescue Membrane::SchemaValidationError => e
          logger.error(logger_prefix + 'failure.invalid-message', staging_guid: droplet.guid, payload: payload, error: e.to_s)

          payload[:error] = { message: 'Malformed message from Diego stager', id: DEFAULT_STAGING_ERROR }
          handle_failure(payload)

          raise CloudController::Errors::ApiError.new_from_details('InvalidRequest', payload)
        end

        begin
          droplet.class.db.transaction do
            droplet.lock!

            droplet.state             = DropletModel::FAILED_STATE
            droplet.error_id          = payload[:error][:id]
            droplet.error_description = payload[:error][:message]
            droplet.save_changes(raise_on_save_failure: true)
          end
        rescue => e
          logger.error(logger_prefix + 'saving-staging-result-failed', staging_guid: droplet.guid, response: payload, error: e.message)
        end

        Loggregator.emit_error(droplet.guid, "Failed to stage droplet: #{payload[:error][:message]}")
      end

      def handle_success(payload, with_start)
        begin
          payload[:result][:process_types] ||= {} if payload[:result]
          self.class.success_parser.validate(payload)
        rescue Membrane::SchemaValidationError => e
          logger.error(logger_prefix + 'success.invalid-message', staging_guid: droplet.guid, payload: payload, error: e.to_s)

          payload[:error] = { message: 'Malformed message from Diego stager', id: DEFAULT_STAGING_ERROR }
          handle_failure(payload)

          raise CloudController::Errors::ApiError.new_from_details('InvalidRequest', payload)
        end

        if payload[:result][:process_types].blank?
          payload[:error] = { message: 'No process types returned from stager', id: DEFAULT_STAGING_ERROR }
          handle_failure(payload)
        else
          begin
            save_staging_result(payload)
            start_process if with_start
          rescue => e
            logger.error(logger_prefix + 'saving-staging-result-failed', staging_guid: droplet.guid, response: payload, error: e.message)
          end
        end
      end

      def start_process
        app         = droplet.app
        web_process = app.web_process

        return if web_process.latest_droplet.guid != droplet.guid

        app.db.transaction do
          app.lock!
          app.update(droplet: droplet)
        end

        @runners.runner_for_app(web_process).start
      end

      def error_parser
        @error_schema ||= Membrane::SchemaParser.parse do
          {
            error: {
              id: String,
              message: String,
            },
          }
        end
      end
    end
  end
end
