require 'net/http'
require 'json'
require 'securerandom'
require 'base64'
require 'uri'

if File.exist?('env.rb')
  #Default environment variables
  require './env'
end

$stdout.sync = true

# ========================
# Config จาก ENV
# ========================
SECRET_NAME       = ENV.fetch("SECRET_NAME")
NAMESPACE         = ENV.fetch("SECRET_NAMESPACE", "default")
RUN_MODE          = ENV.fetch("RUN_MODE", "once")
CHECK_INTERVAL    = ENV.fetch("CHECK_INTERVAL", "30").to_i

KUBE_HOST = ENV.fetch("KUBERNETES_SERVICE_HOST")
KUBE_PORT = ENV.fetch("KUBERNETES_SERVICE_PORT")
TOKEN     = File.read("/var/run/secrets/kubernetes.io/serviceaccount/token")
CA_CERT   = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

# ========================
# กำหนด Secret Keys + pattern
# ========================
SECRET_KEYS = {
  "GRAFANA_USER"     => { fixed: "admin" },
  "GRAFANA_PASSWORD" => { type: :alnum, length: 16 },

  "KEYCLOAK_USER"     => { fixed: "admin" },
  "KEYCLOAK_PASSWORD" => { type: :alnum, length: 16 },

  "ES_USER"     => { fixed: "elastic" },
  "ES_PASSWORD" => { type: :alnum, length: 16 },
  "ES_BASIC_AUTH" => { type: :base64, length: 16 },
  "ES_ROLE"       => { fixed: "superuser" },

  "POSTGRES_USER"     => { fixed: "postgres" },
  "POSTGRES_PASSWORD" => { type: :alnum, length: 16 },

  "ARKIME_USER"     => { fixed: "admin" },
  "ARKIME_PASSWORD" => { type: :alnum, length: 16 },

  "GIT_USER"     => { fixed: "admin" },
  "GIT_PASSWORD" => { type: :alnum, length: 16 },

  "INITIAL_USER"     => { fixed: "admin" },
  "INITIAL_PASSWORD" => { type: :alnum, length: 16 }
}

# ========================
# Helper
# ========================
def generate_value(config)
  case config[:type]
  when :hex
    SecureRandom.hex(config[:length] / 2)
  when :alnum
    SecureRandom.alphanumeric(config[:length])
  when :base64
    Base64.strict_encode64(SecureRandom.random_bytes(config[:length]))
  else
    SecureRandom.alphanumeric(config[:length])
  end
end

def kube_request(method, path, body=nil)
  uri = URI("https://#{KUBE_HOST}:#{KUBE_PORT}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.ca_file = CA_CERT

  req_class = {
    get: Net::HTTP::Get,
    post: Net::HTTP::Post,
    patch: Net::HTTP::Patch
  }[method]

  req = req_class.new(uri)
  req["Authorization"] = "Bearer #{TOKEN}"
  req["Content-Type"] = "application/merge-patch+json"

  req.body = body.to_json if body
  http.request(req)
end

def ensure_secret
  puts "Checking secret #{SECRET_NAME}..."

  res = kube_request(:get, "/api/v1/namespaces/#{NAMESPACE}/secrets/#{SECRET_NAME}")

  if res.code == "404"
    puts "Secret not found. Creating..."

    data = {}
    SECRET_KEYS.each do |key, config|
      data[key] = Base64.strict_encode64(generate_value(config))
    end

    body = {
      apiVersion: "v1",
      kind: "Secret",
      metadata: { name: SECRET_NAME },
      type: "Opaque",
      data: data
    }

    create_res = kube_request(:post, "/api/v1/namespaces/#{NAMESPACE}/secrets", body)
    puts "Create result: #{create_res.code}"
    return
  end

  secret = JSON.parse(res.body)
  existing_data = secret["data"] || {}
  updated_data = {}

  SECRET_KEYS.each do |key, config|
    existing_value = existing_data[key] ? Base64.decode64(existing_data[key]) : nil

    if config[:fixed]
      # ถ้าเป็น fixed value
      if existing_value != config[:fixed]
        puts "Fixing value for #{key}..."
        updated_data[key] = Base64.strict_encode64(config[:fixed])
      end
    else
      # เป็น random value
      unless existing_data.key?(key)
        puts "Generating value for #{key}..."
        new_value = generate_value(config)
        updated_data[key] = Base64.strict_encode64(new_value)
      end
    end
  end

  if updated_data.any?
    puts "Patching secret..."
    patch_res = kube_request(:patch,
      "/api/v1/namespaces/#{NAMESPACE}/secrets/#{SECRET_NAME}",
      { data: updated_data }
    )
    puts "Patch result: #{patch_res.code}"
  else
    puts "Secret OK"
  end
end

# ========================
# Main
# ========================
if RUN_MODE == "loop"
  loop do
    ensure_secret
    sleep CHECK_INTERVAL
  end
else
  ensure_secret
end
