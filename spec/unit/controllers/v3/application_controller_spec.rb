require 'spec_helper'
require 'rails_helper'

describe ApplicationController, type: :controller do
  RSpec::Matchers.define_negated_matcher :not_change, :change

  controller do
    def index
      render 200, json: { request_id: VCAP::Request.current_id }
    end

    def show
      head 204
    end

    def create
      head 201
    end
  end

  describe 'read permission scope validation' do
    before do
      set_current_user(VCAP::CloudController::User.new(guid: 'some-guid'), scopes: ['cloud_controller.write'])
    end

    it 'is required on index' do
      get :index

      expect(response.status).to eq(403)
      expect(parsed_body['description']).to eq('You are not authorized to perform the requested action')
    end

    it 'is required on show' do
      get :show, id: 1

      expect(response.status).to eq(403)
      expect(parsed_body['description']).to eq('You are not authorized to perform the requested action')
    end

    it 'is not required on other actions' do
      post :create

      expect(response.status).to eq(201)
    end

    it 'is not required for admin' do
      set_current_user_as_admin

      post :create
      expect(response.status).to eq(201)
    end
  end

  describe 'write permission scope validation' do
    before do
      set_current_user(VCAP::CloudController::User.new(guid: 'some-guid'), scopes: ['cloud_controller.read'])
    end

    it 'is not required on index' do
      get :index
      expect(response.status).to eq(200)
    end

    it 'is not required on show' do
      get :show, id: 1
      expect(response.status).to eq(204)
    end

    it 'is required on other actions' do
      post :create
      expect(response.status).to eq(403)
      expect(parsed_body['description']).to eq('You are not authorized to perform the requested action')
    end

    it 'is not required for admin' do
      set_current_user_as_admin

      post :create
      expect(response.status).to eq(201)
    end
  end

  describe 'request id' do
    before do
      set_current_user_as_admin
      @request.env.merge!('cf.request_id' => 'expected-request-id')
    end

    it 'sets the vcap request current_id from the passed in rack request during request handling' do
      get :index

      # finding request id inside the controller action and returning on the body
      expect(parsed_body['request_id']).to eq('expected-request-id')
    end

    it 'unsets the vcap request current_id after the request completes' do
      get :index
      expect(VCAP::Request.current_id).to be_nil
    end
  end

  describe 'https schema validation' do
    before do
      set_current_user(VCAP::CloudController::User.make)
      VCAP::CloudController::Config.config[:https_required] = true
    end

    context 'when request is http' do
      before do
        @request.env['rack.url_scheme'] = 'http'
      end

      it 'raises an error' do
        get :index
        expect(response.status).to eq(403)
        expect(parsed_body['description']).to eq('You are not authorized to perform the requested action')
      end
    end

    context 'when request is https' do
      before do
        @request.env['rack.url_scheme'] = 'https'
      end

      it 'is a valid request' do
        get :index
        expect(response.status).to eq(200)
      end
    end
  end

  describe 'auth token validation' do
    context 'when the token contains a valid user' do
      before do
        set_current_user_as_admin
      end

      it 'allows the operation' do
        get :index
        expect(response.status).to eq(200)
      end
    end

    context 'when there is no token' do
      it 'raises NotAuthenticated' do
        get :index
        expect(response.status).to eq(401)
        expect(parsed_body['description']).to eq('Authentication error')
      end
    end

    context 'when the token is invalid' do
      before do
        VCAP::CloudController::SecurityContext.set(nil, :invalid_token, nil)
      end

      it 'raises InvalidAuthToken' do
        get :index
        expect(response.status).to eq(401)
        expect(parsed_body['description']).to eq('Invalid Auth Token')
      end
    end

    context 'when there is a token but no matching user' do
      before do
        user = nil
        VCAP::CloudController::SecurityContext.set(user, 'valid_token', nil)
      end

      it 'raises InvalidAuthToken' do
        get :index
        expect(response.status).to eq(401)
        expect(parsed_body['description']).to eq('Invalid Auth Token')
      end
    end
  end
end
