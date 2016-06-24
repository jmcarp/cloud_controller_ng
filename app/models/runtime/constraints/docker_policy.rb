class DockerPolicy
  BUILDPACK_DETECTED_ERROR_MSG = 'incompatible with buildpack'.freeze
  DOCKER_CREDENTIALS_ERROR_MSG = 'user, password and email required'.freeze
  LIFECYCLE_CHANGE_ERROR_MSG   = 'cannot change from a buildpack app to a docker app'.freeze

  def initialize(app)
    @errors = app.errors
    @app    = app
  end

  def validate
    if @app.docker?
      if @app.buildpack_specified?
        @errors.add(:docker_image, BUILDPACK_DETECTED_ERROR_MSG)
      end

      if VCAP::CloudController::FeatureFlag.disabled?(:diego_docker)
        @errors.add(:docker, :docker_disabled) if @app.being_started?
      end

      if !@app.new? && @app.column_changed?(:docker_image) && @app.initial_value(:docker_image).nil?
        @errors.add(:docker_image, LIFECYCLE_CHANGE_ERROR_MSG)
      end
    end

    docker_credentials = @app.docker_credentials_json
    if docker_credentials.present?
      unless docker_credentials['docker_user'].present? && docker_credentials['docker_password'].present? && docker_credentials['docker_email'].present?
        @errors.add(:docker_credentials, DOCKER_CREDENTIALS_ERROR_MSG)
      end
    end
  end
end
