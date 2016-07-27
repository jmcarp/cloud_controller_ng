module VCAP::CloudController
  module Diego
    class StagingDetails
      attr_accessor :droplet, :staging_memory_in_mb, :staging_disk_in_mb, :environment_variables, :lifecycle
    end
  end
end
