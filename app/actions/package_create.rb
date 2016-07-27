require 'repositories/package_event_repository'

module VCAP::CloudController
  class PackageCreate
    class InvalidPackage < StandardError; end

    def initialize(user_guid, user_email)
      @user_guid = user_guid
      @user_email = user_email
    end

    def create(message)
      logger.info("creating package type #{message.type} for app #{message.app_guid}")

      package              = PackageModel.new
      package.app_guid     = message.app_guid
      package.type         = message.type
      package.state        = get_package_state(message)
      package.docker_image = message.docker_data.image if message.docker_type?

      package.db.transaction do
        package.save

        Repositories::PackageEventRepository.record_app_package_create(
          package,
          @user_guid,
          @user_email,
          message.audit_hash)
      end

      package
    rescue Sequel::ValidationFailed => e
      raise InvalidPackage.new(e.message)
    end

    private

    def get_package_state(message)
      message.bits_type? ? PackageModel::CREATED_STATE : PackageModel::READY_STATE
    end

    def logger
      @logger ||= Steno.logger('cc.action.package_create')
    end
  end
end
