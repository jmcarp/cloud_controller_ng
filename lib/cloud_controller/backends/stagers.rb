require 'cloud_controller/dea/stager'
require 'cloud_controller/diego/stager'
require 'cloud_controller/diego/protocol'
require 'cloud_controller/diego/buildpack/staging_completion_handler'
require 'cloud_controller/diego/buildpack/lifecycle_protocol'
require 'cloud_controller/diego/v3/buildpack/lifecycle_protocol'
require 'cloud_controller/diego/v3/buildpack/staging_completion_handler'
require 'cloud_controller/diego/v3/docker/lifecycle_protocol'
require 'cloud_controller/diego/v3/docker/staging_completion_handler'
require 'cloud_controller/diego/docker/lifecycle_protocol'
require 'cloud_controller/diego/docker/staging_completion_handler'
require 'cloud_controller/diego/egress_rules'
require 'cloud_controller/diego/v3/stager'
require 'cloud_controller/diego/v3/messenger'
require 'cloud_controller/diego/v3/protocol/package_staging_protocol'

module VCAP::CloudController
  class Stagers
    def initialize(config, message_bus, dea_pool)
      @config      = config
      @message_bus = message_bus
      @dea_pool    = dea_pool
    end

    def validate_app(app)
      if app.docker? && FeatureFlag.disabled?(:diego_docker)
        raise CloudController::Errors::ApiError.new_from_details('DockerDisabled')
      end

      if app.package_hash.blank?
        raise CloudController::Errors::ApiError.new_from_details('AppPackageInvalid', 'The app package hash is empty')
      end

      if app.buildpack.custom? && !app.custom_buildpacks_enabled?
        raise CloudController::Errors::ApiError.new_from_details('CustomBuildpacksDisabled')
      end

      if Buildpack.count == 0 && app.buildpack.custom? == false
        raise CloudController::Errors::ApiError.new_from_details('NoBuildpacksFound')
      end
    end

    def stager_for_package(package, lifecycle_type)
      if package.app.processes.any? { |p| p.diego? }
        Diego::V3::Stager.new(package, lifecycle_type, @config)
      else
        Dea::Stager.new(package, @config, @message_bus, @dea_pool)
      end
    end

    private

    def dependency_locator
      CloudController::DependencyLocator.instance
    end
  end
end
