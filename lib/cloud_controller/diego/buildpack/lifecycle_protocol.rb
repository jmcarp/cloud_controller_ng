require 'cloud_controller/diego/buildpack/lifecycle_data'
require 'cloud_controller/diego/buildpack/buildpack_entry_generator'

module VCAP
  module CloudController
    module Diego
      module Buildpack
        class LifecycleProtocol
          def initialize(blobstore_url_generator=::CloudController::DependencyLocator.instance.blobstore_url_generator)
            @blobstore_url_generator = blobstore_url_generator
            @buildpack_entry_generator = BuildpackEntryGenerator.new(@blobstore_url_generator)
          end

          def lifecycle_data(package, staging_details)
            lifecycle_data                                    = Diego::Buildpack::LifecycleData.new
            lifecycle_data.app_bits_download_uri              = @blobstore_url_generator.package_download_url(package)
            lifecycle_data.build_artifacts_cache_download_uri = @blobstore_url_generator.buildpack_cache_download_url(
              package.app_guid,
              staging_details.lifecycle.staging_stack
            )
            lifecycle_data.build_artifacts_cache_upload_uri   = @blobstore_url_generator.buildpack_cache_upload_url(
              package.app_guid,
              staging_details.lifecycle.staging_stack
            )
            lifecycle_data.droplet_upload_uri                 = @blobstore_url_generator.droplet_upload_url(staging_details.droplet.guid)
            lifecycle_data.buildpacks                         = @buildpack_entry_generator.buildpack_entries(staging_details.lifecycle.buildpack_info)
            lifecycle_data.stack                              = staging_details.lifecycle.staging_stack

            lifecycle_data.message
          end

          def desired_app_message(process)
            {
              'start_command' => process.command.nil? ? process.detected_start_command : process.command,
              'droplet_uri' => @blobstore_url_generator.unauthorized_perma_droplet_download_url(process),
              'droplet_hash' => process.current_droplet.droplet_hash,
            }
          end
        end
      end
    end
  end
end
