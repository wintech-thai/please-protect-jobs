#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'uri'
require 'openssl'

if File.exist?('env.rb')
  #Default environment variables
  require './env'
end

$stdout.sync = true

IDP_URL           = ENV.fetch("IDP_URL")
CLIENT_ID         = ENV.fetch("IDP_CLIENT_ID")
REALM_NAME        = ENV.fetch("IDP_REALM")
ADMIN_USER        = ENV.fetch("IDP_USER")
ADMIN_PASSWORD    = ENV.fetch("IDP_PASSWORD")

def http_request(method, url, token: nil, body: nil)
  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)

  if uri.scheme == "https"
    http.use_ssl = true

    if ENV["IDP_INSECURE_SKIP_VERIFY"] == "true"
      # ⚠ ใช้เฉพาะ dev / internal cluster
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    else
      # default ปลอดภัย
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    end
  end

  request =
    case method
    when :get    then Net::HTTP::Get.new(uri)
    when :post   then Net::HTTP::Post.new(uri)
    when :put    then Net::HTTP::Put.new(uri)
    when :delete then Net::HTTP::Delete.new(uri)
    else raise "Unsupported method"
    end

  request["Content-Type"] = "application/json"
  request["Authorization"] = "Bearer #{token}" if token
  request.body = body.to_json if body

  response = http.request(request)

  if response.code.to_i >= 400
    raise "HTTP #{response.code}: #{response.body}"
  end

  response
end

def admin_token
  uri = URI.parse("#{IDP_URL}/realms/master/protocol/openid-connect/token")

  http = Net::HTTP.new(uri.host, uri.port)

  if uri.scheme == "https"
    http.use_ssl = true

    if ENV["IDP_INSECURE_SKIP_VERIFY"] == "true"
      # ⚠ ใช้เฉพาะ dev / internal cluster
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    else
      # default ปลอดภัย
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    end
  end

  http.open_timeout = 10
  http.read_timeout = 30

  request = Net::HTTP::Post.new(uri)
  request.set_form_data({
    "grant_type" => "password",
    "client_id"  => "admin-cli",
    "username"   => ADMIN_USER,
    "password"   => ADMIN_PASSWORD
  })

  response = http.request(request)

  unless response.code.to_i == 200
    raise "Token request failed: #{response.code} #{response.body}"
  end

  JSON.parse(response.body)["access_token"]
end

token = admin_token
puts "Authenticated."

# --------------------------
# REALM (create or update)
# --------------------------

realms_res = http_request(:get, "#{IDP_URL}/admin/realms", token: token)
realms = JSON.parse(realms_res.body)

realm_exists = realms.any? { |r| r["realm"] == REALM_NAME }

if realm_exists
  puts "Realm exists. Updating..."
  http_request(:put, "#{IDP_URL}/admin/realms/#{REALM_NAME}",
    token: token,
    body: { realm: REALM_NAME, enabled: true }
  )
else
  puts "Creating realm..."
  http_request(:post, "#{IDP_URL}/admin/realms",
    token: token,
    body: { realm: REALM_NAME, enabled: true }
  )
end

# --------------------------
# CLIENT (create or update)
# --------------------------

clients_res = http_request(:get, "#{IDP_URL}/admin/realms/#{REALM_NAME}/clients?clientId=#{CLIENT_ID}", token: token)
clients = JSON.parse(clients_res.body)

if clients.empty?
  puts "Creating client..."
  http_request(:post, "#{IDP_URL}/admin/realms/#{REALM_NAME}/clients",
    token: token,
    body: {
      clientId: CLIENT_ID,
      enabled: true,
      protocol: "openid-connect",
      serviceAccountsEnabled: true,
      publicClient: false,
    }
  )
  clients_res = http_request(:get, "#{IDP_URL}/admin/realms/#{REALM_NAME}/clients?clientId=#{CLIENT_ID}", token: token)
  clients = JSON.parse(clients_res.body)
else
  puts "Client exists. Updating..."
  client_uuid = clients.first["id"]
  http_request(:put, "#{IDP_URL}/admin/realms/#{REALM_NAME}/clients/#{client_uuid}",
    token: token,
    body: {
      clientId: CLIENT_ID,
      enabled: true,
      protocol: "openid-connect",
      serviceAccountsEnabled: true,
      publicClient: false
    }
  )
end

client_uuid = clients.first["id"]

# --------------------------
# ASSIGN realm-admin role
# --------------------------

puts "Assigning realm-admin role..."

sa_user = JSON.parse(
  http_request(:get,
    "#{IDP_URL}/admin/realms/#{REALM_NAME}/clients/#{client_uuid}/service-account-user",
    token: token
  ).body
)

realm_admin_client = JSON.parse(
  http_request(:get,
    "#{IDP_URL}/admin/realms/#{REALM_NAME}/clients?clientId=realm-management",
    token: token
  ).body
).first

realm_admin_role = JSON.parse(
  http_request(:get,
    "#{IDP_URL}/admin/realms/#{REALM_NAME}/clients/#{realm_admin_client['id']}/roles/realm-admin",
    token: token
  ).body
)

http_request(:post,
  "#{IDP_URL}/admin/realms/#{REALM_NAME}/users/#{sa_user['id']}/role-mappings/clients/#{realm_admin_client['id']}",
  token: token,
  body: [realm_admin_role]
)

# --------------------------
# REMOVE rsa-enc-generated
# --------------------------

puts "Ensuring only rsa-generated key exists..."

components = JSON.parse(
  http_request(
    :get,
    "#{IDP_URL}/admin/realms/#{REALM_NAME}/components?type=org.keycloak.keys.KeyProvider",
    token: token
  ).body
)

enc_component = components.find { |c| c["name"] == "rsa-enc-generated" }

if enc_component
  puts "Deleting component #{enc_component['id']} (rsa-enc-generated)..."

  http_request(
    :delete,
    "#{IDP_URL}/admin/realms/#{REALM_NAME}/components/#{enc_component['id']}",
    token: token
  )
else
  puts "No rsa-enc-generated component found."
end

puts "Done."
