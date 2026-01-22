#!/usr/bin/env ruby

require 'pg'
require 'time'
require 'uri'
require 'redis'
require './utils'

def load_cache_aggregate(dbConn, redisObj, aggrType)
  puts("DEBUG : Start loading aggregated data [#{aggrType}] from Redis...\n")

  cnt = 0
  upsertCount = 0
  redisObj.scan_each(match: "#{aggrType}!!*") do |key|
      lastSeen = redisObj.get(key).to_i

      lastSeenStr = Time.at(lastSeen).strftime("%Y-%m-%d %H:%M:%S")

      namespace, oicType, dataSet, iocValue = key.split("!!")

      cnt = cnt + 1
      puts("DEBUG_00 : [#{cnt}] Loading [#{namespace}] [#{oicType}] [#{dataSet}] [#{iocValue}] [#{lastSeenStr}]\n")

      upsertKey = "UPSERT_#{aggrType}:#{key}"
      previousLastSeen = redisObj.get(upsertKey).to_i

      needUpsert = false
      if (previousLastSeen.nil?)
        # Never seen that data in cache
        needUpsert = true
      else
        if (previousLastSeen != lastSeen)
          # Need to call upsert
          needUpsert = true
        end
      end

needUpsert = true # ทดสอบให้ upsert ตลอดเวลาก่อน 

      if (needUpsert)
        upsertData(dbConn, aggrType, key, lastSeen, cnt)
        upsertCount = upsertCount + 1

        redisObj.setex(upsertKey, 86400, lastSeen)
      end
  end

  puts("DEBUG : Done loading [#{aggrType}] readCount=[#{cnt}], upsertCount=[#{upsertCount}] to PostgreSQL\n")
  return cnt
end

def escape_char(str)
  return "#{str}".tr("'", "")
end

def upsertData(dbConn, type, keyword, lastSeenDate, seq)

  if (keyword.nil?)
    puts("INFO : keyword is null in upsertData()\n")
    return
  end

  namespace, oicType, dataSet, iocValue = keyword.split("!!")

  orgId = "default"
  time = Time.at(lastSeenDate).utc

  #puts("INFO : [#{seq}] [#{type}] [#{dateStr}] [#{aggregatorPod}] [#{attributes}] --> [#{aggrCount}]")
  
  begin
    dbConn.transaction do |con|
        con.exec "INSERT INTO \"Iocs\" 
        (
            ioc_id,
            org_id,
            dataset,
            ioc_type,
            ioc_sub_type,
            ioc_value,
            tags,
            created_date,
            last_seen_date
        )
        VALUES
        (
            gen_random_uuid(),
            '#{escape_char(orgId)}',
            '#{escape_char(dataSet)}',
            '#{escape_char(dataSet)}',
            '#{escape_char(oicType)}',
            '#{escape_char("")}',
            '#{escape_char(iocValue)}',
            '#{escape_char("")}',
             current_timestamp,
            #{time}
        )
        ON CONFLICT(org_id, ioc_type, dataset, ioc_value, ioc_sub_type)
        DO UPDATE SET last_seen_date = #{time}
        "
    end
  rescue PG::Error => e
    puts("ERROR - Insert data to DB upsertData() [#{e.message}]")
    exit 102 # Terminate immediately
  end
end


##### Main #####
#####
if File.exist?('env.rb')
  #Default environment variables
  require './env'
end

$stdout.sync = true

environment = ENV['ENVIRONMENT']
redisHost = ENV['REDIS_HOST']
redisPort = ENV['REDIS_PORT']

puts("INFO : ### Start dispatching jobs.")
puts("INFO : ### ENVIRONMENT=[#{environment}]")
puts("INFO : ### REDIS_HOST=[#{redisHost}]")
puts("INFO : ### REDIS_PORT=[#{redisPort}]")

pgHost = ENV["PG_HOST"]
pgDb = ENV["PG_DB"]
conn = connect_db(pgHost, pgDb, ENV["PG_USER"], ENV["PG_PASSWORD"])
if (conn.nil?)
  puts("ERROR : ### Unable to connect to PostgreSQL --> Host=[#{pgHost}], DB=[#{pgDb}] !!!")
  exit 101
end
puts("INFO : ### Connected to PostgreSQL [#{pgHost}] [#{pgDb}]")

redis = Redis.new(host: redisHost, port: redisPort)

puts("INFO - Starting program to load IOC aggregated data to PostgreSQL...")

type = 'aggr_network_blacklist_dest_ip_v1'
totalLoad = load_cache_aggregate(conn, redis, 'IOC_SEEN')
