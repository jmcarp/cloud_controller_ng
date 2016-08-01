require 'actions/v2/route_mapping_create'

module VCAP::CloudController
  class RouteMappingsController < RestController::ModelController
    define_attributes do
      attribute :app_guid, String, exclude_in: [:update]
      to_one :route, exclude_in: [:update]
      attribute :app_port, Integer, default: nil
    end

    model_class_name :RouteMappingModel

    query_parameters :app_guid, :route_guid

    def create
      json_msg       = self.class::CreateMessage.decode(body)
      @request_attrs = json_msg.extract(stringify_keys: true)
      logger.debug 'cc.create', model: self.class.model_class_name, attributes: redact_attributes(:create, request_attrs)

      route   = Route.where(guid: request_attrs['route_guid']).eager(:space).all.first
      process = App.where(guid: request_attrs['app_guid']).eager(app: :space).all.first

      raise CloudController::Errors::ApiError.new_from_details('RouteNotFound', request_attrs['route_guid']) unless route
      raise CloudController::Errors::ApiError.new_from_details('AppNotFound', request_attrs['app_guid']) unless process
      raise CloudController::Errors::ApiError.new_from_details('NotAuthorized') unless Permissions.new(SecurityContext.current_user).can_write_to_space?(process.space.guid)

      route_mapping = V2::RouteMappingCreate.new(SecurityContext.current_user, SecurityContext.current_user_email, route, process).add(request_attrs)

      if !request_attrs.key?('app_port') && !process.ports.blank?
        add_warning("Route has been mapped to app port #{route_mapping.app_port}.")
      end

      [
        HTTP::CREATED,
        { 'Location' => "#{self.class.path}/#{route_mapping.guid}" },
        object_renderer.render_json(self.class, route_mapping, @opts)
      ]

    rescue RouteMappingCreate::DuplicateRouteMapping
      raise CloudController::Errors::ApiError.new_from_details('RouteMappingTaken', route_mapping_taken_message(request_attrs))
    rescue RouteMappingCreate::UnavailableAppPort
      raise CloudController::Errors::ApiError.new_from_details('RoutePortNotEnabledOnApp')
    rescue V2::RouteMappingCreate::TcpRoutingDisabledError
      raise CloudController::Errors::ApiError.new_from_details('TcpRoutingDisabled')
    rescue V2::RouteMappingCreate::RouteServiceNotSupportedError
      raise CloudController::Errors::InvalidRelation.new('Route services are only supported for apps on Diego')
    rescue V2::RouteMappingCreate::AppPortNotSupportedError
      raise CloudController::Errors::ApiError.new_from_details('AppPortMappingRequiresDiego')
    rescue RouteMappingCreate::SpaceMismatch => e
      raise CloudController::Errors::InvalidRelation.new(e.message)
    end

    def delete(guid)
      route_mapping = find_guid_and_validate_access(:delete, guid)

      do_delete(route_mapping)
    end

    define_messages
    define_routes

    private

    def get_app_port(app_guid, app_port)
      if app_port.blank?
        app = App.find(guid: app_guid)
        if !app.nil?
          return app.ports[0] unless app.ports.blank?
        end
      end

      app_port
    end

    def route_mapping_taken_message(request_attrs)
      app_guid = request_attrs['app_guid']
      route_guid = request_attrs['route_guid']
      app_port = get_app_port(app_guid, request_attrs['app_port'])

      error_message =  "Route #{route_guid} is mapped to "
      error_message += "port #{app_port} of " unless app_port.blank?
      error_message += "app #{app_guid}"

      error_message
    end
  end
end
