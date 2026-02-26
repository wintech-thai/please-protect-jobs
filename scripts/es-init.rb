#!/usr/bin/env ruby

require 'net/http'
require 'uri'
require 'json'
require 'openssl'

REQUIRED_ENVS = %w[
  ES_USER
  ES_PASSWORD
  ES_URL
  INDEX_TEMPLATE_NAME
  INDEX_ILM_POLICY
  INDEX_NAME
]

missing = REQUIRED_ENVS.select { |k| ENV[k].nil? || ENV[k].empty? }
abort "Missing ENV: #{missing.join(', ')}" unless missing.empty?

es_user         = ENV['ES_USER']
es_password     = ENV['ES_PASSWORD']
es_url          = ENV['ES_URL'].chomp('/')
template_name   = ENV['INDEX_TEMPLATE_NAME']
ilm_name        = ENV['INDEX_ILM_POLICY']
index_pattern   = ENV['INDEX_NAME']

SHARDS      = ENV.fetch('INDEX_SHARDS', 1).to_i
REPLICAS    = ENV.fetch('INDEX_REPLICAS', 0).to_i
WARM_DAYS   = ENV.fetch('WARM_DAYS', 30).to_i
COLD_DAYS   = ENV.fetch('COLD_DAYS', 60).to_i
DELETE_DAYS = ENV.fetch('DELETE_DAYS', 90).to_i

def http_request(method, url, body=nil, user=nil, pass=nil)
  uri = URI(url)
  klass = {
    get: Net::HTTP::Get,
    put: Net::HTTP::Put
  }[method]

  req = klass.new(uri)
  req.basic_auth(user, pass)
  req['Content-Type'] = 'application/json'
  req.body = body.to_json if body

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE

  http.request(req)
end

def create_if_missing(get_url, put_url, body, user, pass, name)
  res = http_request(:get, get_url, nil, user, pass)

  if res.code == "404"
    puts "Creating #{name}..."
    put_res = http_request(:put, put_url, body, user, pass)
    unless put_res.code.start_with?("2")
      abort "Failed creating #{name}: #{put_res.code} #{put_res.body}"
    end
    puts "✔ #{name} created"
  elsif res.code.start_with?("2")
    puts "✔ #{name} already exists — skipping"
  else
    abort "Error checking #{name}: #{res.code} #{res.body}"
  end
end

# ===== ILM Policy =====
ilm_body = {
  policy: {
    phases: {
      hot:  { min_age: "0ms", actions: {} },
      warm: { min_age: "#{WARM_DAYS}d", actions: {} },
      cold: { min_age: "#{COLD_DAYS}d", actions: {} },
      delete: {
        min_age: "#{DELETE_DAYS}d",
        actions: { delete: {} }
      }
    }
  }
}

create_if_missing(
  "#{es_url}/_ilm/policy/#{ilm_name}",
  "#{es_url}/_ilm/policy/#{ilm_name}",
  ilm_body,
  es_user,
  es_password,
  "ILM policy #{ilm_name}"
)

# ===== Index Template =====
template_body = {
  index_patterns: [index_pattern],
  template: {
    settings: {
      "index.lifecycle.name": ilm_name,
      "number_of_shards": SHARDS,
      "number_of_replicas": REPLICAS
    }
  }
}

create_if_missing(
  "#{es_url}/_index_template/#{template_name}",
  "#{es_url}/_index_template/#{template_name}",
  template_body,
  es_user,
  es_password,
  "Index template #{template_name}"
)

puts "\nDone."
