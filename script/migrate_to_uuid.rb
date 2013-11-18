#!/usr/bin/env ruby

require 'pg'
require 'redis'

DBHOST = '127.0.0.1'
DBUSER = 'postgres'
DBNAME = 'carto_db_development'
REDIS_HOST = '127.0.0.1'
ENVIRONMENT = 'development'

@actions = ['schema', 'rollback', 'meta', 'clean', 'data']

ACTION = ARGV[0]

def usage()
  puts "Usage: #{__FILE__} <action>"
  puts "Actions:"
  @actions.each {|a| puts "  #{a}"}
  exit 1
end

if ACTION.nil? || !@actions.include?(ACTION)
  usage()
end

@logs = Hash.new

tables = {
           :api_keys => {
             :related => [],
             :singular => 'api_key'
           },
           :assets => { 
             :related => [],
             :singular => 'asset'
           },
           :client_applications => {
             :related => [],
             :singular => 'client_application'
           },
           :data_imports => {
             :related => ['user_tables'],
             :singular => 'data_import'
           },
           :geocodings => {
             :related => [],
             :singular => 'geocoding'
           },
           :layers => {
             :related => ['layers_maps', 'layers_users', 'layers_user_tables', 'visualizations'],
             :singular => 'layer',
             :relation_for => {'visualizations' => 'active_layer'}
           },
           :layers_maps => {
             :related => [],
             :singular => 'layer_map'
           },
           :layers_user_tables => {
             :related => [],
             :singular => 'layer_user_table'
           },
           :layers_users => {
             :related => [],
             :singular => 'layer_user'
           },
           :maps => {
             :related => ['user_tables', 'layers_maps', 'visualizations'],
             :singular => 'map'
           },
           :oauth_nonces => {
             :related => [],
             :singular => 'oauth_nonce'
           },
           :oauth_tokens => {
             :related => [],
             :singular => 'oauth_token'
           },
           :overlays => {
             :related => [],
             :singular => 'overlay'
           },
           :tags => {
             :related => [],
             :singular => 'tag'
           },
           :user_tables => {
             :related => ['data_imports', 'layers_user_tables', 'tags'],
             :singular => 'table',
             :relation_for => {'layers_user_tables' => 'user_table'}
           },
           :users => {
             :related => ['user_tables', 'maps', 'layers_users', 'assets', 'api_keys', 'client_applications', 'oauth_tokens', 'tags', 'data_imports', 'synchronizations', 'geocodings'],
             :singular => 'user'
           },
           #:visualizations => {
           #  :related => ['overlays'],
           #  :singular => 'visualization'
           #}
         }

redis_keys = {
              :map_style => {
                :template => "map_style|USERDB|*",
                :var_position => 1,
                :separator => '|',
                :db => 0,
                :type => 'string'
              },
              :table => {
                :template => "rails:USERDB:*",
                :var_position => 1, 
                :separator => ':',
                :db => 0,
                :type => 'hash',
                :attributes => {
                  :user_id => 'USERID'
                }
              },
              :user => {
                :template => "rails:users:USERNAME",
                :no_clone => true,
                :var_position => 2,
                :separator => ':',
                :db => 5,
                :type => 'hash',
                :attributes => {
                  :database_name => 'USERDB',
                  :id => 'USERID'
                }
              }
            }

def redis_replace_from_template(template, id, username)
  if template.include?('USERDB')
    user_database(id)
  elsif template.include?('DBUSER')
    database_username(id)
  elsif template.include?('USERNAME')
    username
  elsif template.include?('USERID')
    id
  else
    '' 
  end
end

def redis_template_user_gsub(template, id, username)
  replacement = redis_replace_from_template(template, id, username)
  if template.include?('USERDB')
    template.gsub('USERDB', replacement)
  elsif template.include?('DBUSER')
    template.gsub('DBUSER', replacement)
  elsif template.include?('USERNAME')
    template.gsub('USERNAME', replacement)
  else
    '' 
  end
end

def copy_redis_keys(redis_keys, id, uuid, username)
  redis = Redis.new(:host => REDIS_HOST)
  redis_keys.each do |k,v|
    redis.select(v[:db])
    these_redis_keys = redis.keys(redis_template_user_gsub(v[:template], id, username))
    these_redis_keys.each do |trd|
        original_value = redis.dump(trd)
        new_array = trd.split(v[:separator])
        new_array[v[:var_position]] = redis_replace_from_template(v[:template], uuid, username)
        new_key = new_array.join(v[:separator])
      unless v[:no_clone]
        redis.restore(new_key, 0, original_value)
      end
      if v[:type] == 'hash'
        v[:attributes].each do |a,av|
          redis.hset(new_key, a.to_s, redis_replace_from_template(av, uuid, username))
        end
      end
    end
  end
  redis.quit
end
  
def relation_column_name_for(tables, table, related)
  if tables[table][:related].include?(related) && tables[table][:relation_for] && tables[table][:relation_for][related]
    tables[table][:relation_for][related]
  else
    tables[table][:singular]
  end
end


def log(severity, type, msg)
  puts "    #{msg}. Ignoring.."
  @logs.merge({:severity => severity, :type => type, :msg => msg})
end

def database_username(user_id)
  "#{db_username_prefix}#{user_id}"
end #database_username

def user_database(user_id)
  "#{database_name_prefix}#{user_id}_db"
end #user_database

def db_username_prefix
  return "cartodb_user_" if ENVIRONMENT == 'production'
  return "development_cartodb_user_" if ENVIRONMENT == 'development'
  "cartodb_user_#{ENVIRONMENT}_"
end #username_prefix

def database_name_prefix
  return "cartodb_user_" if ENVIRONMENT == 'production'
  return "cartodb_dev_user_" if ENVIRONMENT == 'development'
  "cartodb_#{ENVIRONMENT}_user_"
end #database_prefix

def alter_schema(tables) 
  tables.each do |tname, tinfo|
    # Create main uuid column in every table
    puts "Creating uuid column in #{tname}"
    begin
      @conn.exec("ALTER TABLE #{tname} ADD uuid uuid UNIQUE NOT NULL DEFAULT uuid_generate_v4()")
    rescue => e
      log('C', "Creating uuid column in #{tname}", e.error.strip)
    end
    tinfo[:related].each do |rtable|
      # Create relation uuid column in a dependent table
      puts "Creating #{relation_column_name_for(tables, tname, rtable)}_uuid column in related table #{rtable}"
      begin
        @conn.exec("ALTER TABLE #{rtable} ADD #{relation_column_name_for(tables, tname, rtable)}_uuid uuid")
      rescue => e
        log('C', "Creating #{relation_column_name_for(tables, tname, rtable)}_uuid column in related table #{rtable}", e.error.strip)
      end
    end
  end
end

def rollback_schema(tables)
  tables.each do |tname, tinfo|
    tinfo[:related].each do |rtable|
      # Create relation uuid column in a dependent table
      puts "Dropping #{relation_column_name_for(tables, tname, rtable)}_uuid column in related table #{rtable}"
      begin
        @conn.exec("ALTER TABLE #{rtable} DROP IF EXISTS #{relation_column_name_for(tables, tname, rtable)}_uuid")
      rescue => e
        log('C', "Dropping #{relation_column_name_for(tables, tname, rtable)}_uuid column in related table #{rtable}", e.error.strip)
      end
    end
    # Destroy main uuid column in every table
    puts "Dropping uuid column in #{tname}"
    begin
      @conn.exec("ALTER TABLE #{tname} DROP IF EXISTS uuid")
    rescue => e
      log('C', "Dropping uuid column in #{tname}", e.error.strip)
    end
  end
end

def migrate_meta(tables)
  tables.each do |tname, tinfo|
    @conn.exec("SELECT id,uuid FROM #{tname}") do |result|
      result.each do |row|
        tinfo[:related].each do |rtable|
          puts "Setting #{relation_column_name_for(tables, tname, rtable)}_uuid in #{rtable}"
          begin
            @conn.exec("UPDATE #{rtable} SET #{relation_column_name_for(tables, tname, rtable)}_uuid='#{row['uuid']}' WHERE #{relation_column_name_for(tables, tname, rtable)}_id=#{row['id']}")        
          rescue => e
            log('C', "Setting #{relation_column_name_for(tables, tname, rtable)}_uuid in #{rtable}", e.error.strip)
          end
        end
      end
    end
  end
end


def migrate_data(redis_keys)
  sconn = PGconn.connect( host: DBHOST, user: 'postgres', dbname: 'postgres' )
  @conn.exec("SELECT id,uuid,database_name,username FROM users") do |result|
    result.each do |row|
      puts "Renaming pg user and db for id #{row['id']}"
      begin
        sconn.exec("ALTER DATABASE \"#{row['database_name']}\" RENAME TO \"#{user_database(row['uuid'])}\"")
        sconn.exec("ALTER ROLE \"#{database_username(row['id'])}\" RENAME TO \"#{database_username(row['uuid'])}\"")
        @conn.exec("UPDATE users SET database_name='#{user_database(row['uuid'])}' WHERE id=#{row['id']} AND uuid='#{row['uuid']}'")
      rescue => e
        log('C', "Renaming pg user and db for id #{row['id']}", e.error.strip)
      end
      puts "Copying redis keys with uuid for id #{row['id']}"
      #begin
        copy_redis_keys(redis_keys, row['id'], row['uuid'], row['username'])
      #rescue => e
      #  log('C', "Copying redis keys with uuid for id #{row['id']}", e.error.strip)
      #end
    end
  end
end

def clean_db(tables) 
  tables.each do |tname, tinfo|
    tinfo[:related].each do |rtable|
      # Drop old id relation column in every table
      puts "Dropping #{relation_column_name_for(tables, tname, rtable)}_id from #{rtable}"
      begin
        @conn.exec("ALTER TABLE #{rtable} DROP IF EXISTS #{relation_column_name_for(tables, tname, rtable)}_id")
      rescue => e
        log('C', "Dropping #{relation_column_name_for(tables, tname, rtable)}_id from #{rtable}", e.error.strip)
      end
      # Rename new uuid relation column to id
      puts "Renaming #{relation_column_name_for(tables, tname, rtable)}_uuid to #{relation_column_name_for(tables, tname, rtable)}_id in #{rtable}"
      begin
        @conn.exec("ALTER TABLE #{rtable} RENAME #{relation_column_name_for(tables, tname, rtable)}_uuid TO #{relation_column_name_for(tables, tname, rtable)}_id")
      rescue => e
        log('C', "Renaming #{relation_column_name_for(tables, tname, rtable)}_uuid to #{relation_column_name_for(tables, tname, rtable)}_id in #{rtable}", e.error.strip)
      end
    end
    # Drop old id column in every table
    puts "Dropping old id from #{tname}"
    begin
      @conn.exec("ALTER TABLE #{tname} DROP IF EXISTS id")
    rescue => e
      log('C', "Dropping old id from #{rtable}", e.error.strip)
    end
    # Rename new uuid relation column to id
    puts "Renaming uuid to id in #{tname}"
    begin
      @conn.exec("ALTER TABLE #{tname} RENAME uuid TO id")
    rescue => e
      log('C', "Renaming uuid to id in #{tname}", e.error.strip)
    end
    # Set new id as primary key
    puts "Setting new id as primary key on #{tname}"
    begin
      @conn.exec("ALTER TABLE #{tname} ADD PRIMARY KEY (id)")
    rescue => e
      log('C', "Setting new id as primary key on #{tname}", e.error.strip)
    end
  end
end

@conn = PGconn.connect( host: DBHOST, user: DBUSER, dbname: DBNAME )
@conn.exec("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"")

if ACTION == 'schema'
  alter_schema(tables)
elsif ACTION == 'rollback'
  rollback_schema(tables)
elsif ACTION == 'meta'
  migrate_meta(tables)
elsif ACTION == 'data'
  migrate_data(redis_keys)
elsif ACTION == 'clean'
  clean_db(tables)
end

puts ""
puts "#############"
puts "#{@logs.length} errors"
puts "#############"
