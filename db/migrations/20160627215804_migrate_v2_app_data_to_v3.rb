Sequel.migration do
  up do
    dbtype = if self.class.name.match(/mysql/i)
               'mysql'
             elsif self.class.name.match(/postgres/i)
               'postgres'
             else
               raise 'unknown database'
             end

    ####
    ##  App usage events
    ####
    generate_stop_events_query = <<-SQL
        INSERT INTO app_usage_events
          (guid, created_at, instance_count, memory_in_mb_per_instance, state, app_guid, app_name, space_guid, space_name, org_guid, buildpack_guid, buildpack_name, package_state, parent_app_name, parent_app_guid, process_type, task_guid, task_name, package_guid, previous_state, previous_package_state, previous_memory_in_mb_per_instance, previous_instance_count)
        SELECT %s, now(), p.instances, p.memory, 'STOPPED', p.guid, p.name, s.guid, s.name, o.guid, d.buildpack_receipt_buildpack_guid, COALESCE(d.buildpack_receipt_buildpack, l.buildpack), p.package_state, a.name, a.guid, p.type, NULL, NULL, pkg.guid, 'STARTED', p.package_state, p.memory, p.instances
          FROM apps as p
            INNER JOIN apps_v3 as a ON (a.guid=p.app_guid)
            INNER JOIN spaces as s ON (s.guid=a.space_guid)
            INNER JOIN organizations as o ON (o.id=s.organization_id)
            INNER JOIN packages as pkg ON (a.guid=pkg.app_guid)
            INNER JOIN v3_droplets as d ON (a.guid=d.app_guid)
            INNER JOIN buildpack_lifecycle_data as l ON (d.guid=l.droplet_guid)
          WHERE p.state='STARTED'
    SQL
    if dbtype == 'mysql'
      run generate_stop_events_query % 'UUID()'
    elsif dbtype =='postgres'
      run generate_stop_events_query % 'get_uuid()'
    end

    ###
    ##  V3 data removal
    ###
    alter_table(:packages) do
      drop_foreign_key [:app_guid]
    end
    alter_table(:apps) do
      drop_foreign_key [:app_guid]
      drop_index :app_guid
      drop_foreign_key [:space_id]
      drop_foreign_key [:stack_id], name: :fk_apps_stack_id
      drop_index [:name, :space_id], name: :apps_space_id_name_nd_idx
    end
    alter_table(:route_mappings) do
      drop_foreign_key [:app_guid]
    end
    alter_table(:v3_service_bindings) do
      drop_foreign_key [:app_id]
    end
    drop_table(:tasks)
    drop_table(:package_docker_data)
    drop_table(:v3_droplets)

    run 'DELETE FROM droplets WHERE app_id IN (SELECT id FROM apps WHERE app_guid IS NOT NULL);'
    run 'DELETE FROM apps_routes WHERE app_id IN (SELECT id FROM apps WHERE app_guid IS NOT NULL);'
    run 'DELETE FROM apps WHERE app_guid IS NOT NULL OR deleted_at IS NOT NULL;'
    self[:route_mappings].truncate
    self[:packages].truncate
    self[:buildpack_lifecycle_data].truncate
    self[:v3_service_bindings].truncate
    self[:apps_v3].truncate

    rename_table :apps, :processes
    rename_table :apps_v3, :apps

    alter_table(:processes) do
      add_index :app_guid
      add_foreign_key [:app_guid], :apps, key: :guid, name: :fk_processes_app_guid
    end
    alter_table(:packages) do
      add_foreign_key [:app_guid], :apps, key: :guid, name: :fk_packages_app_guid
    end
    alter_table(:route_mappings) do
      add_foreign_key [:app_guid], :apps, key: :guid, name: :fk_route_mappings_app_guid
    end
    alter_table(:v3_service_bindings) do
      add_foreign_key [:app_id], :apps, key: :id, name: :fk_v3_service_bindings_app_id   # this is by id instead of guid
    end

    ####
    ## Backfill apps table
    ###
    run <<-SQL
        INSERT INTO apps (guid, name, salt, encrypted_environment_variables, created_at, updated_at, space_guid)
        SELECT p.guid, p.name, p.salt, p.encrypted_environment_json, p.created_at, p.updated_at, s.guid
        FROM processes as p, spaces as s
        WHERE p.space_id = s.id
        ORDER BY p.id
    SQL

    run <<-SQL
        UPDATE processes SET app_guid=guid
    SQL

    #####
    ## App Lifecycle
    ####
    alter_table(:buildpack_lifecycle_data) do
      drop_index(:guid)
      set_column_allow_null(:guid)
    end

    run <<-SQL
        INSERT INTO buildpack_lifecycle_data (app_guid, stack)
        SELECT processes.guid, stacks.name
        FROM processes, stacks
        WHERE docker_image is NULL AND stacks.id = processes.stack_id
    SQL

    run <<-SQL
        UPDATE buildpack_lifecycle_data
        SET buildpack=(
          SELECT buildpacks.name
          FROM buildpacks
            JOIN processes ON processes.admin_buildpack_id = buildpacks.id
          WHERE processes.admin_buildpack_id IS NOT NULL AND processes.guid=buildpack_lifecycle_data.app_guid
        )
    SQL

    run <<-SQL
        UPDATE buildpack_lifecycle_data
        SET buildpack=(
          SELECT processes.buildpack
          FROM processes
          WHERE processes.admin_buildpack_id IS NULL AND processes.guid=buildpack_lifecycle_data.app_guid
        )
        WHERE buildpack IS NULL
    SQL

    #####
    ## Backfill packages
    ####
    alter_table(:packages) do
      drop_column :url
      add_column :docker_image, String, type: :text
    end

    run <<-SQL
      INSERT INTO packages (guid, type, package_hash, state, error, app_guid)
      SELECT guid, 'bits', package_hash, 'READY', NULL, guid
        FROM processes
      WHERE package_hash IS NOT NULL AND docker_image IS NULL
    SQL

    run <<-SQL
      INSERT INTO packages (guid, type, state, error, app_guid, docker_image)
      SELECT  guid, 'docker', 'READY', NULL, guid, docker_image
        FROM processes
      WHERE docker_image IS NOT NULL
    SQL

    ####
    ## Backfill droplets
    ####

    alter_table :droplets do
      add_column :state, String
      add_index :state, name: :droplets_state_index
      add_column :process_types, String, type: :text
      add_column :error_id, String
      add_column :error_description, String, type: :text
      add_column :encrypted_environment_variables, String, text: true
      add_column :salt, String
      add_column :staging_memory_in_mb, Integer
      add_column :staging_disk_in_mb, Integer

      add_column :buildpack_receipt_stack_name, String
      add_column :buildpack_receipt_buildpack, String
      add_column :buildpack_receipt_buildpack_guid, String
      add_column :docker_receipt_image, String

      add_column :package_guid, String
      add_index :package_guid, name: :package_guid_index

      add_column :app_guid, String
      add_foreign_key [:app_guid], :apps, key: :guid, name: :fk_droplets_app_guid

      set_column_allow_null(:droplet_hash)
    end

    # backfill any v2 droplets that do not exist due to lazy backfilling in v2 droplets.  it is unlikely there are
    # any of these, but possible in very old CF deployments
    run <<-SQL
      INSERT INTO droplets (guid, app_id, droplet_hash, detected_start_command)
      SELECT processes.guid, processes.id, processes.droplet_hash, '' AS detected_start_command
        FROM processes
      WHERE processes.droplet_hash IS NOT NULL
        AND processes.id IN ( SELECT processes.id FROM processes LEFT JOIN droplets ON processes.id = droplets.app_id WHERE droplets.id IS NULL)
    SQL

    # pruning will not delete from the blobstore
    postgres_prune_droplets_query = <<-SQL
      DELETE FROM droplets
      USING droplets as d
        JOIN processes ON processes.id = d.app_id
      WHERE droplets.id = d.id AND processes.droplet_hash <> d.droplet_hash
    SQL

    mysql_prune_droplets_query = <<-SQL
      DELETE droplets FROM droplets
        JOIN processes ON processes.id = droplets.app_id
      WHERE processes.droplet_hash <> droplets.droplet_hash
    SQL

    if dbtype == 'mysql'
      run mysql_prune_droplets_query
    elsif dbtype =='postgres'
      run postgres_prune_droplets_query
    end

    # convert to v3 droplets
    postgres_convert_to_v3_droplets_query = <<-SQL
        UPDATE droplets
        SET
          guid = v2_app.guid,
          state = 'STAGED',
          app_guid = v2_app.guid,
          package_guid = v2_app.guid,
          docker_receipt_image = droplets.cached_docker_image,
          process_types = '{"web":"' || droplets.detected_start_command || '"}'
        FROM processes AS v2_app
        WHERE v2_app.id = droplets.app_id
    SQL

    mysql_convert_to_v3_droplets_query = <<-SQL
        UPDATE droplets
        JOIN processes as v2_app
          ON v2_app.id = droplets.app_id
        SET
          droplets.guid = v2_app.guid,
          droplets.state = 'STAGED',
          droplets.app_guid = v2_app.guid,
          droplets.package_guid = v2_app.guid,
          droplets.docker_receipt_image = droplets.cached_docker_image,
          droplets.process_types = CONCAT('{"web":"', droplets.detected_start_command, '"}')
    SQL

    if dbtype == 'mysql'
      run mysql_convert_to_v3_droplets_query
    elsif dbtype =='postgres'
      run postgres_convert_to_v3_droplets_query
    end

    # add lifecycle data
    run <<-SQL
      INSERT INTO buildpack_lifecycle_data (droplet_guid)
      SELECT droplets.guid
        FROM processes, droplets
      WHERE processes.docker_image is NULL AND droplets.app_guid = processes.guid
    SQL

    # set current droplet on v3 app
    postgres_set_current_droplet_query = <<-SQL
      UPDATE apps
      SET droplet_guid = current_droplet.guid
      FROM droplets current_droplet, processes web_process
      WHERE web_process.droplet_hash IS NOT NULL
        AND web_process.app_guid = apps.guid
        AND web_process.type = 'web'
        AND current_droplet.app_guid = apps.guid
        AND current_droplet.droplet_hash = web_process.droplet_hash
    SQL

    mysql_set_current_droplet_query = <<-SQL
      UPDATE apps
      JOIN droplets as current_droplet
        ON apps.guid = current_droplet.app_guid
      JOIN processes as web_process
        ON web_process.app_guid = apps.guid AND web_process.type = 'web'
      SET apps.droplet_guid = current_droplet.guid
      WHERE web_process.droplet_hash IS NOT NULL AND current_droplet.droplet_hash = web_process.droplet_hash
    SQL

    if dbtype == 'mysql'
      run mysql_set_current_droplet_query
    elsif dbtype =='postgres'
      run postgres_set_current_droplet_query
    end

    alter_table :droplets do
      set_column_not_null(:state)
      drop_column :app_id
      drop_column :cached_docker_image
      drop_column :detected_start_command
    end

    ####
    ## Recreate tasks table
    ####

    create_table :tasks do
      VCAP::Migration.common(self)

      String :name, case_insensitive: true, null: false
      index :name, name: :tasks_name_index
      String :command, null: false, text: true
      String :state, null: false
      index :state, name: :tasks_state_index
      Integer :memory_in_mb, null: true
      String :encrypted_environment_variables, text: true, null: true
      String :salt, null: true
      String :failure_reason, null: true, size: 4096

      String :app_guid, null: false
      foreign_key [:app_guid], :apps, key: :guid, name: :fk_tasks_app_guid

      String :droplet_guid, null: false
      foreign_key [:droplet_guid], :droplets, key: :guid, name: :fk_tasks_droplet_guid

      if self.class.name.match(/mysql/i)
        table_name = tables.find { |t| t =~ /tasks/ }
        run "ALTER TABLE `#{table_name}` CONVERT TO CHARACTER SET utf8;"
      end
    end

    ####
    ## Fill in guids for buildpack_lifecycle_data inserts done for apps and droplets
    ####

    if self.class.name.match(/mysql/i)
      run 'update buildpack_lifecycle_data set guid=UUID();'
    elsif self.class.name.match(/postgres/i)
      run 'update buildpack_lifecycle_data set guid=get_uuid();'
    end

    alter_table(:buildpack_lifecycle_data) do
      set_column_not_null :guid
      add_index :guid, unique: true, name: :buildpack_lifecycle_data_guid_index
    end

    ####
    ## Remove columns that have moved to other tables
    ####

    alter_table(:processes) do
      drop_column :name
      drop_column :encrypted_environment_json
      drop_column :salt
      drop_column :buildpack
      drop_column :space_id
      drop_column :stack_id
      drop_column :admin_buildpack_id
      drop_column :docker_image
      drop_column :package_hash
      drop_column :package_state
      drop_column :droplet_hash
      drop_column :package_pending_since
      drop_column :deleted_at
      drop_column :staging_task_id
      drop_column :detected_buildpack_guid
      drop_column :detected_buildpack_name
      drop_column :staging_failed_reason
      drop_column :staging_failed_description
    end
  end
end
