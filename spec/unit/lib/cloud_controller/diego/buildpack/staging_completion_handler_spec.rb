require 'spec_helper'
require 'cloud_controller/diego/buildpack/staging_completion_handler'

module VCAP::CloudController
  module Diego
    module Buildpack
      RSpec.describe StagingCompletionHandler do
        let(:logger) { instance_double(Steno::Logger, info: nil, error: nil, warn: nil) }
        let(:buildpack) { VCAP::CloudController::Buildpack.make(name: 'INTERCAL') }
        let(:success_response) do
          {
            result: {
              lifecycle_type:     'buildpack',
              lifecycle_metadata: {
                buildpack_key:      buildpack.key,
                detected_buildpack: 'INTERCAL',
              },
              execution_metadata: '',
              process_types:      {
                web: 'some command'
              }
            }
          }
        end
        let(:malformed_success_response) do
          success_response[:result].except(:execution_metadata)
        end
        let(:fail_response) do
          {
            error: { id: 'NoCompatibleCell', message: 'Found no compatible cell' }
          }
        end
        let(:malformed_fail_response) do
          { error: { id: 'stuff' } }
        end

        subject { StagingCompletionHandler.new(staged_droplet) }

        describe '#staging_complete' do
          let(:app) { AppModel.make }
          let(:package) { PackageModel.make(app_guid: app.guid) }
          let(:staged_droplet) { DropletModel.make(app_guid: app.guid, package_guid: package.guid, state: 'PENDING') }
          let(:staging_guid) { staged_droplet.guid }

          before do
            allow(Steno).to receive(:logger).with('cc.stager').and_return(logger)
            allow(Loggregator).to receive(:emit_error)
          end

          describe 'success case' do
            it 'marks the droplet as staged' do
              expect {
                subject.staging_complete(success_response)
              }.to change { staged_droplet.reload.staged? }.to(true)
            end

            context 'when staging result is returned' do
              before do
                success_response[:result][:process_types] = {
                  web:      'start me',
                  worker:   'hello',
                  anything: 'hi hi hi'
                }

                success_response[:result][:execution_metadata] = 'black-box-string'
              end

              it 'updates the droplet with the metadata' do
                subject.staging_complete(success_response)
                staged_droplet.reload
                droplet = staged_droplet
                data    = {
                  'web'      => 'start me',
                  'worker'   => 'hello',
                  'anything' => 'hi hi hi'
                }

                expect(droplet.execution_metadata).to eq('black-box-string')
                expect(droplet.process_types).to eq(data)
                expect(droplet.buildpack_receipt_buildpack).to eq('INTERCAL')
                expect(droplet.buildpack_receipt_buildpack_guid).to eq(buildpack.guid)
              end

              context 'when process_types is empty' do
                before do
                  success_response[:result][:process_types] = nil
                end

                it 'gracefully sets process_types to an empty hash, but mark the droplet as failed' do
                  subject.staging_complete(success_response)
                  expect(staged_droplet.reload.state).to eq(DropletModel::FAILED_STATE)
                  expect(staged_droplet.error).to eq('StagingError - No process types returned from stager')
                end
              end

              context 'when detected_buildpack is empty' do
                before do
                  staged_droplet.buildpack_lifecycle_data = BuildpackLifecycleDataModel.make(buildpack: 'OG BP', stack: 'on stacks on stacks')
                  staged_droplet.save

                  success_response[:result][:lifecycle_metadata][:detected_buildpack] = ''
                  success_response[:result][:lifecycle_metadata][:buildpack_key]      = ''
                end

                it 'uses the lifecycle data buildpack' do
                  subject.staging_complete(success_response)
                  expect(staged_droplet.reload.buildpack_receipt_buildpack).to eq('OG BP')
                end
              end
            end

            context 'when updating the droplet record with data from staging fails' do
              let(:save_error) { StandardError.new('save-error') }

              before do
                allow_any_instance_of(DropletModel).to receive(:save_changes).and_raise(save_error)
              end

              it 'logs an error for the CF operator' do
                subject.staging_complete(success_response)

                expect(logger).to have_received(:error).with(
                  'diego.staging.saving-staging-result-failed',
                  staging_guid: staged_droplet.guid,
                  response:     success_response,
                  error:        'save-error',
                )
              end
            end
          end

          describe 'failure case' do
            context 'when the staging fails' do
              it 'should mark the droplet as failed' do
                subject.staging_complete(fail_response)
                expect(staged_droplet.reload.state).to eq(DropletModel::FAILED_STATE)
              end

              it 'records the error' do
                subject.staging_complete(fail_response)
                expect(staged_droplet.reload.error).to eq('NoCompatibleCell - Found no compatible cell')
              end

              it 'should emit a loggregator error' do
                expect(Loggregator).to receive(:emit_error).with(staged_droplet.guid, /Found no compatible cell/)
                subject.staging_complete(fail_response)
              end
            end

            context 'with a malformed success message' do
              before do
                expect {
                  subject.staging_complete(malformed_success_response)
                }.to raise_error(CloudController::Errors::ApiError)
              end

              it 'logs an error for the CF operator' do
                expect(logger).to have_received(:error).with(
                  'diego.staging.success.invalid-message',
                  staging_guid: staged_droplet.guid,
                  payload:      malformed_success_response,
                  error:        '{ result => Missing key }'
                )
              end

              it 'logs an error for the CF user' do
                expect(Loggregator).to have_received(:emit_error).with(staged_droplet.guid, /Malformed message from Diego stager/)
              end

              it 'should mark the droplet as failed' do
                expect(staged_droplet.reload.state).to eq(DropletModel::FAILED_STATE)
              end
            end

            context 'with a malformed error message' do
              it 'should mark the droplet as failed' do
                expect {
                  subject.staging_complete(malformed_fail_response)
                }.to raise_error(CloudController::Errors::ApiError)

                expect(staged_droplet.reload.state).to eq(DropletModel::FAILED_STATE)
                expect(staged_droplet.error).to eq('StagingError - Malformed message from Diego stager')
              end

              it 'logs an error for the CF user' do
                expect {
                  subject.staging_complete(malformed_fail_response)
                }.to raise_error(CloudController::Errors::ApiError)

                expect(Loggregator).to have_received(:emit_error).with(staged_droplet.guid, /Malformed message from Diego stager/)
              end

              it 'logs an error for the CF operator' do
                expect {
                  subject.staging_complete(malformed_fail_response)
                }.to raise_error(CloudController::Errors::ApiError)

                expect(logger).to have_received(:error).with(
                  'diego.staging.failure.invalid-message',
                  staging_guid: staged_droplet.guid,
                  payload:      malformed_fail_response,
                  error:        '{ error => { message => Missing key } }'
                )
              end
            end

            context 'when updating the droplet record with data from staging fails' do
              let(:save_error) { StandardError.new('save-error') }

              before do
                allow_any_instance_of(DropletModel).to receive(:save_changes).and_raise(save_error)
              end

              it 'logs an error for the CF operator' do
                subject.staging_complete(fail_response)

                expect(logger).to have_received(:error).with(
                  'diego.staging.saving-staging-result-failed',
                  staging_guid: staged_droplet.guid,
                  response:     fail_response,
                  error:        'save-error',
                )
              end
            end
          end
        end
      end
    end
  end
end
