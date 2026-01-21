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
      lastSeen = redisObj.get(key)

      lastSeenStr = Time.at(ts).strftime("%Y-%m-%d %H:%M:%S")

      namespace, oicType, dataSet, iocValue = key.split("!!")

      cnt = cnt + 1
      puts("DEBUG_00 : [#{cnt}] Loading [#{namespace}] [#{oicType}] [#{dataSet}] [#{iocValue}] [#{lastSeenStr}]\n")

      upsertKey = "UPSERT_#{aggrType}:#{key}"
      previousLastSeen = redisObj.get(upsertKey)

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
        #upsertData(dbConn, type, keyword, aggrCount, cnt)
        upsertCount = upsertCount + 1

        redisObj.setex(upsertKey, 86400, lastSeen)
      end
  end

  puts("DEBUG : Done loading [#{aggrType}] readCount=[#{cnt}], upsertCount=[#{upsertCount}] to PostgreSQL\n")
  return cnt
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
