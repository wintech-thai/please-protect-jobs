#!/usr/bin/env ruby

require 'pg'
require 'time'
require './utils'

if File.exist?('env.rb')
  #Default environment variables
  require './env'
end

$stdout.sync = true

# เชื่อมต่อกับ PostgreSQL
pgHost = ENV["PG_HOST"]
pgDb = ENV["PG_DB"]
conn = connect_db(pgHost, pgDb, ENV["PG_USER"], ENV["PG_PASSWORD"])
if (conn.nil?)
  puts("ERROR : ### Unable to connect to PostgreSQL --> Host=[#{pgHost}], DB=[#{pgDb}] !!!")
  exit 101
end
puts("INFO : ### Connected to PostgreSQL [#{pgHost}] [#{pgDb}]")

jobId = fallback(ENV['JOB_ID'], '')
fromVersion = ENV['FROM_VERSION']
toVersion = ENV['TO_VERSION']

puts("INFO : ### Start upgrading program from #{fromVersion} to #{toVersion}...")

successCnt = 1
failedCnt = 0

update_job_status(conn, jobId, 'Running') unless jobId == ""

message = "Done upgrading program from #{fromVersion} to #{toVersion}." 
update_job_done(conn, jobId, successCnt, failedCnt, message) unless jobId == ""

puts(message)
