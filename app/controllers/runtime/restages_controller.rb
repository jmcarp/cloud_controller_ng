require 'actions/v2/app_stage'

module VCAP::CloudController
  class RestagesController < RestController::ModelController
    def self.dependencies
      [:app_event_repository, :stagers]
    end

    path_base 'apps'
    model_class_name :App

    def inject_dependencies(dependencies)
      super
      @app_event_repository = dependencies.fetch(:app_event_repository)
      @stagers               = dependencies.fetch(:stagers)
    end

    post "#{path_guid}/restage", :restage

    def restage(guid)
      process = find_guid_and_validate_access(:read, guid)

      model.db.transaction do
        process.app.lock!
        process.lock!

        if process.pending?
          raise CloudController::Errors::ApiError.new_from_details('NotStaged')
        end

        process.stop!
        process.app.update(droplet_guid: nil)
        process.reload
        process.start!
      end

      V2::AppStage.new(
        user:       SecurityContext.current_user,
        user_email: SecurityContext.current_user_email,
        stagers:    @stagers
      ).stage(process)

      @app_event_repository.record_app_restage(process, SecurityContext.current_user.guid, SecurityContext.current_user_email)

      [
        HTTP::CREATED,
        { 'Location' => "#{self.class.path}/#{process.guid}" },
        object_renderer.render_json(self.class, process, @opts)
      ]
    end

    def self.translate_validation_exception(e, attributes)
      docker_errors = e.errors.on(:docker)
      return CloudController::Errors::ApiError.new_from_details('DockerDisabled') if docker_errors

      CloudController::Errors::ApiError.new_from_details('StagingError', e.errors.full_messages)
    end
  end
end
