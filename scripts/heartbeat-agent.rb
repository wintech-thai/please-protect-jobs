#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'uri'
require 'pg'
require 'time'
require 'securerandom'

if File.exist?('env.rb')
  require './env'
end

$stdout.sync = true

CHECK_INTERVAL = (ENV['CHECK_INTERVAL'] || 30).to_i
AUDIT_ENDPOINT = ENV['AUDIT_ENDPOINT']

NODE_ID_FILE = "/data/node_id"
INTERFACE_MANAGER_URL = "http://interface-manager-service.pp-system.svc.cluster.local/interfaces/all"

# ==========================
# NODE ID
# ==========================

def get_node_id
  if File.exist?(NODE_ID_FILE)
    return File.read(NODE_ID_FILE).strip
  end

  id = SecureRandom.uuid

  begin
    File.write(NODE_ID_FILE, id)
  rescue => e
    puts "ERROR writing node ID file: #{e}"
  end

  id
end

NODE_ID = get_node_id

# ==========================
# PostgreSQL
# ==========================

def pg_conn
  PG.connect(
    host: ENV['PG_HOST'],
    port: ENV['PG_PORT'],
    user: ENV['PG_USER'],
    password: ENV['PG_PASSWORD'],
    dbname: ENV['PG_DATABASE']
  )
end

def load_cloud_config(conn)

  result = conn.exec <<~SQL
    select config_type, config_value
    from "Configurations"
    where config_type in ('CloudConnectFlag','CloudConnectKey','CloudUrl');
  SQL

  config = {}

  result.each do |row|
    config[row['config_type']] = row['config_value']
  end

  config
end

# ==========================
# SYSTEM METRICS
# ==========================

def get_cpu_usage

  stat1 = File.readlines("/host/proc/stat").first.split.map(&:to_i)
  sleep 0.5
  stat2 = File.readlines("/host/proc/stat").first.split.map(&:to_i)

  idle1 = stat1[4]
  idle2 = stat2[4]

  total1 = stat1.sum
  total2 = stat2.sum

  total_diff = total2 - total1
  idle_diff = idle2 - idle1

  usage = 100.0 * (total_diff - idle_diff) / total_diff

  { usage_percent: usage.round(2) }
end

def get_memory

  meminfo = {}

  File.readlines("/host/proc/meminfo").each do |line|
    key, value = line.split(":")
    meminfo[key] = value.strip.split.first.to_i
  end

  total = meminfo["MemTotal"] / 1024
  free = meminfo["MemAvailable"] / 1024
  used = total - free

  {
    total_mb: total,
    used_mb: used,
    free_mb: free,
    usage_percent: ((used.to_f / total) * 100).round(2)
  }
end

def get_disk

  disks = []

  `df -P`.split("\n")[1..].each do |line|

    parts = line.split

    total = parts[1].to_i / 1024 / 1024
    used = parts[2].to_i / 1024 / 1024
    percent = parts[4].gsub('%','').to_i

    disks << {
      mount: parts[5],
      total_gb: total,
      used_gb: used,
      usage_percent: percent
    }
  end

  disks
end

def get_uptime
  File.read("/host/proc/uptime").split.first.to_i
end

def get_hostname
  `hostname`.strip
end

# ==========================
# INTERFACE MANAGER
# ==========================

def get_interfaces

  uri = URI.parse(INTERFACE_MANAGER_URL)

  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = 2
  http.read_timeout = 3

  request = Net::HTTP::Get.new(uri)

  response = http.request(request)

  if response.code.to_i != 200
    puts "WARNING: interface manager returned #{response.code}"
    return []
  end

  JSON.parse(response.body)

rescue => e
  puts "ERROR fetching interfaces: #{e}"
  []
end

# ==========================
# MACHINE STATUS
# ==========================

def get_machine_status

  {
    node_id: NODE_ID,
    hostname: get_hostname,
    uptime_sec: get_uptime,
    timestamp: Time.now.utc.iso8601,

    cpu: get_cpu_usage,
    memory: get_memory,
    disk: get_disk,

    interfaces: get_interfaces
  }
end

# ==========================
# HTTP REQUEST
# ==========================
def make_request(method, url, apiKey, data)

  uri = URI.parse(url)

  klass_name = "Net::HTTP::#{method.to_s.capitalize}"
  request_class = Object.const_get(klass_name)

  request = request_class.new(uri)
  request['Content-Type'] = 'application/json'

  request.basic_auth("api", apiKey) unless apiKey.nil?

  request.body = data.to_json unless data.nil?

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"

  http.open_timeout = 5
  http.read_timeout = 10

  response = http.request(request)
  raw_body = response.body

  body =
    begin
      JSON.parse(raw_body)
    rescue
      raw_body.nil? ? nil : raw_body[0,50]
    end

  {
    status: response.code.to_i,
    body: body
  }
end

# ==========================
# AUDIT LOG
# ==========================

def send_audit_log(request_data, response_data)

  return if AUDIT_ENDPOINT.nil?

  uri = URI.parse(AUDIT_ENDPOINT)

  req = Net::HTTP::Post.new(uri)
  req['Content-Type'] = 'application/json'

  req.body = {
    timestamp: Time.now.utc,
    request: request_data,
    response: response_data,
    environment: ENV['ENVIRONMENT'] || "unknown",
    AuditType: "CloudConnect",
  }.to_json

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"

  http.open_timeout = 3
  http.read_timeout = 5

  http.request(req)

rescue => e
  puts "AUDIT ERROR: #{e}"
end

# ==========================
# MAIN LOOP
# ==========================

conn = nil

loop do

  begin

    # reconnect database ถ้า connection หาย
    if conn.nil? || conn.finished?
      puts "Connecting PostgreSQL..."
      conn = pg_conn
    end

    config = load_cloud_config(conn)

    required = ['CloudConnectFlag','CloudConnectKey','CloudUrl']
    missing = required.select { |k| !config.key?(k) }

    if !missing.empty?
      puts "ERROR: Missing config in DB: #{missing.join(', ')}"
      sleep CHECK_INTERVAL + rand(5)
      next
    end

    cloud_enabled = config['CloudConnectFlag'] == "true"
    cloud_key = config['CloudConnectKey']
    cloud_url = config['CloudUrl']

    if cloud_url.nil? || cloud_url.empty?
      puts "ERROR: CloudUrl is empty"
      sleep CHECK_INTERVAL + rand(5)
      next
    end

    unless cloud_enabled
      puts "CloudConnectFlag disabled"
      sleep CHECK_INTERVAL + rand(5)
      next
    end

    status = get_machine_status

    puts "Sending heartbeat..."

    response = make_request(
      "post",
      cloud_url,
      cloud_key,
      status
    )

    http_status = response[:status]

    puts "Cloud response status: #{http_status}"

    if http_status == 401
      puts "ERROR: Authentication failed (401). Check CloudConnectKey."
    end

    send_audit_log(status, response)

  rescue PG::Error => e
    puts "PostgreSQL ERROR: #{e}"
    conn = nil

  rescue => e
    puts "ERROR: #{e}"
  end

  sleep CHECK_INTERVAL + rand(5)
end
