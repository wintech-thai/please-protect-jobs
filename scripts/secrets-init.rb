require 'net/http'
require 'json'
require 'securerandom'
require 'base64'
require 'uri'

if File.exist?('env.rb')
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
# Secret Definition
# ========================
SECRET_KEYS = {

  "GRAFANA_USER"     => { fixed: "admin" },
  "GRAFANA_PASSWORD" => { type: :alnum, length: 16 },

  "KEYCLOAK_USER"     => { fixed: "admin" },
  "KEYCLOAK_PASSWORD" => { type: :alnum, length: 16 },

  "ES_USER"     => { fixed: "admin" },
  "ES_PASSWORD" => { type: :alnum, length: 16 },
  "ES_BASIC_AUTH" => { derived: ["ES_USER","ES_PASSWORD"], format: "%s:%s", encode: :base64 },
  "ES_ROLE"       => { fixed: "superuser" },

  "POSTGRES_USER"     => { fixed: "postgres" },
  "POSTGRES_PASSWORD" => { type: :alnum, length: 16 },

  "ARKIME_USER"     => { fixed: "admin" },
  "ARKIME_PASSWORD" => { type: :alnum, length: 16 },

  "GIT_USER"     => { fixed: "admin" },
  "GIT_PASSWORD" => { type: :alnum, length: 16 },

  "INITIAL_USER"     => { fixed: "admin" },
  "INITIAL_PASSWORD" => { type: :alnum, length: 16 },

  "IDP_CLIENT_ID_DEV"      => { fixed: "pp-api" },
  "IDP_CLIENT_SECRET_DEV"  => { fixed: "notused" },
  "IDP_REALM_DEV"          => { fixed: "pp-dev" },
  "IDP_URL_PREFIX_DEV"     => { fixed: "http://keycloak.keycloak.svc.cluster.local" },

  "IDP_CLIENT_ID_PROD"     => { fixed: "pp-api" },
  "IDP_CLIENT_SECRET_PROD" => { fixed: "notused" },
  "IDP_REALM_PROD"         => { fixed: "pp-prod" },
  "IDP_URL_PREFIX_PROD"    => { fixed: "http://keycloak.keycloak.svc.cluster.local" },
}

# ========================
# Helpers
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
    SecureRandom.alphanumeric(config[:length] || 16)
  end
end

def resolve_raw_values(existing={})
  values = {}

  # pass 1: fixed / random
  SECRET_KEYS.each do |key, config|

    if existing[key]
      values[key] = existing[key]
      next
    end

    if config[:fixed]
      values[key] = config[:fixed]

    elsif config[:type]
      values[key] = generate_value(config)

    end
  end

  # pass 2: derived values
  SECRET_KEYS.each do |key, config|

    next unless config[:derived]

    sources = config[:derived].map { |k| values[k] }

    if config[:format]
      value = config[:format] % sources
    else
      value = sources.join(":")
    end
puts("Derived #{key} from #{config[:derived].join(", ")} => #{value}")
    if config[:encode] == :base64
      value = Base64.strict_encode64(value)
    end

    values[key] = value
  end

  values
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

  if body
    req["Content-Type"] =
      method == :patch ? "application/merge-patch+json" : "application/json"

    req.body = body.to_json
  end

  http.request(req)
end

# ========================
# Core Logic
# ========================
def ensure_secret

  puts "Checking secret #{SECRET_NAME}..."

  res = kube_request(:get, "/api/v1/namespaces/#{NAMESPACE}/secrets/#{SECRET_NAME}")

  unless ["200","404"].include?(res.code)
    puts "Error fetching secret #{res.code}"
    puts res.body
    return
  end

  # ========================
  # CREATE
  # ========================
  if res.code == "404"

    puts "Secret not found. Creating..."

    raw_values = resolve_raw_values

    data = {}

    raw_values.each do |k,v|
      data[k] = Base64.strict_encode64(v)
    end

    body = {
      apiVersion: "v1",
      kind: "Secret",
      metadata: { name: SECRET_NAME },
      type: "Opaque",
      data: data
    }

    create_res = kube_request(
      :post,
      "/api/v1/namespaces/#{NAMESPACE}/secrets",
      body
    )

    puts "Create result: #{create_res.code}"
    return
  end

  # ========================
  # PATCH
  # ========================
  secret = JSON.parse(res.body)

  existing_data = secret["data"] || {}

  existing_raw = {}

  existing_data.each do |k,v|
    existing_raw[k] = Base64.decode64(v) rescue nil
  end

  desired = resolve_raw_values(existing_raw)

  updated_data = {}

  desired.each do |k,v|

    encoded = Base64.strict_encode64(v)

    if existing_data[k] != encoded
      puts "Updating #{k}"
      updated_data[k] = encoded
    end
  end

  if updated_data.any?

    puts "Patching secret..."

    patch_res = kube_request(
      :patch,
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
