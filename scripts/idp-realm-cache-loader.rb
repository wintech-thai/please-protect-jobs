#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'uri'
require 'openssl'
require 'redis'

if File.exist?('env.rb')
  #Default environment variables
  require './env'
end

$stdout.sync = true

# -------------------------
# ENV
# -------------------------

ENVIRONMENT = ENV.fetch("ENVIRONMENT")
REDIS_HOST  = ENV.fetch("REDIS_HOST")
REDIS_PORT  = ENV.fetch("REDIS_PORT")

IDP_URL       = ENV.fetch("IDP_URL")
IDP_CLIENT_ID = ENV.fetch("IDP_CLIENT_ID")
IDP_REALM     = ENV.fetch("IDP_REALM")
IDP_USER      = ENV.fetch("IDP_USER")
IDP_PASSWORD  = ENV.fetch("IDP_PASSWORD")

# -------------------------
# Generic HTTP helper
# -------------------------

def http_request(method, url, options = {})
  token   = options[:token]
  form    = options[:form]
  body    = options[:body]

  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)

  if uri.scheme == "https"
    http.use_ssl = true

    if ENV["IDP_INSECURE_SKIP_VERIFY"] == "true"
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    else
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    end
  end

  http.open_timeout = 10
  http.read_timeout = 30

  request =
    case method
    when :get    then Net::HTTP::Get.new(uri)
    when :post   then Net::HTTP::Post.new(uri)
    when :put    then Net::HTTP::Put.new(uri)
    else raise "Unsupported method"
    end

  request["Authorization"] = "Bearer #{token}" if token

  if form
    request.set_form_data(form)
  elsif body
    request["Content-Type"] = "application/json"
    request.body = body.to_json
  end

  response = http.request(request)

  if response.code.to_i >= 400
    raise "HTTP #{response.code}: #{response.body}"
  end

  response
end

# -------------------------
# 1️⃣ Get admin token
# -------------------------

def admin_token
  res = http_request(
    :post,
    "#{IDP_URL}/realms/master/protocol/openid-connect/token",
    form: {
      "grant_type" => "password",
      "client_id"  => "admin-cli",
      "username"   => IDP_USER,
      "password"   => IDP_PASSWORD
    }
  )

  JSON.parse(res.body)["access_token"]
end

# -------------------------
# 2️⃣ Get client UUID
# -------------------------

def client_uuid(token)
  res = http_request(
    :get,
    "#{IDP_URL}/admin/realms/#{IDP_REALM}/clients?clientId=#{IDP_CLIENT_ID}",
    token: token
  )

  clients = JSON.parse(res.body)
  raise "Client not found" if clients.empty?

  clients.first["id"]
end

# -------------------------
# 3️⃣ Get client secret
# -------------------------

def client_secret(token, uuid)
  res = http_request(
    :get,
    "#{IDP_URL}/admin/realms/#{IDP_REALM}/clients/#{uuid}/client-secret",
    token: token
  )

  JSON.parse(res.body)["value"]
end

# -------------------------
# 4️⃣ Write to Redis
# -------------------------

def write_to_redis(secret)
  redis = Redis.new(host: REDIS_HOST, port: REDIS_PORT.to_i)

  key = "realm-client-secret:#{ENVIRONMENT}:#{IDP_CLIENT_ID}"

  redis.set(key, secret)

  puts "Updated Redis key: #{key}"
end

# -------------------------
# Main
# -------------------------

begin
  puts "Authenticating to Keycloak..."
  token = admin_token

  puts "Resolving client UUID..."
  uuid = client_uuid(token)

  puts "Fetching client secret..."
  secret = client_secret(token, uuid)

  puts "Writing to Redis..."
  write_to_redis(secret)

  puts "Sync completed successfully."

rescue => e
  puts "ERROR: #{e.message}"
  exit 1
end
