#!/usr/bin/env ruby

require 'pg'
require 'time'
require 'json'
require 'open3'
require 'fileutils'
require 'securerandom'
require 'net/http'
require 'uri'
require './utils'

if File.exist?('env.rb')
  require './env'
end

$stdout.sync = true

SOURCE_TEMPLATE = ENV['GIT_SOURCE_TEMPLATE']
DEST_TEMPLATE   = ENV['GIT_DEST_TEMPLATE']
TEMP_DIR        = ENV.fetch('TEMP_DIR', '/tmp')

RAW_CONFIG = {
  "mappings" => [
    {
      "source"        => { "repo" => "$GIT_SOURCE_REPO1", "ref_branch" => "$GIT_SOURCE_REF_NAME1" },
      "destination"   => { "repo" => "$GIT_DEST_REPO1",   "branch"     => "$GIT_DEST_REF_NAME1" },
      "is_data_plane" => true,
      "transform"     => {
        "exclude_files" => ["values-local.yaml"],
        "ignore_paths"  => [".git", "node_modules"]
      }
    },
    {
      "source"        => { "repo" => "$GIT_SOURCE_REPO2", "ref_branch" => "$GIT_SOURCE_REF_NAME2" },
      "destination"   => { "repo" => "$GIT_DEST_REPO2",   "branch"     => "$GIT_DEST_REF_NAME2" },
      "is_data_plane" => false,
      "transform"     => {
        "exclude_files" => ["values-local.yaml"],
        "ignore_paths"  => [".git", "node_modules"]
      }
    },
    {
      "source"        => { "repo" => "$GIT_SOURCE_REPO3", "ref_branch" => "$GIT_SOURCE_REF_NAME3" },
      "destination"   => { "repo" => "$GIT_DEST_REPO3",   "branch"     => "$GIT_DEST_REF_NAME3" },
      "is_data_plane" => false,
      "transform"     => {
        "exclude_files" => ["values-local.yaml"],
        "ignore_paths"  => [".git", "node_modules"]
      }
    }
  ]
}

# ---- helpers (reused from git-sync.rb) ----

def resolve_env(value)
  return value unless value.is_a?(String)
  value.gsub(/\$([A-Z0-9_]+)/) do
    ENV[$1] || raise("Missing ENV: #{$1}")
  end
end

def resolve_config(obj)
  case obj
  when Hash   then obj.transform_values { |v| resolve_config(v) }
  when Array  then obj.map              { |v| resolve_config(v) }
  when String then resolve_env(obj)
  else obj
  end
end

def run_cmd(cmd, dir = TEMP_DIR)
  puts "INFO : >> #{cmd}"
  stdout, stderr, status = Open3.capture3(cmd, chdir: dir)
  puts stdout unless stdout.strip.empty?
  puts stderr unless stderr.strip.empty?
  raise "Command failed: #{cmd}\n#{stderr}" unless status.success?
end

def build_url(template, repo, token: nil)
  url = template.gsub("{repo}", repo)
  return url unless token
  if url.start_with?("https://")
    url.sub("https://", "https://#{token}@")
  elsif url.start_with?("http://")
    url.sub("http://", "http://#{token}@")
  else
    url
  end
end

def text_file?(path)
  return false unless File.file?(path)
  File.open(path, "rb") { |f| f.read(1024) }.count("\x00") == 0
end

# ---- data plane: replace repoURL in applications/app-*.yaml ----

def replace_repo_url_in_app_yamls(work_dir, local_repo_url)
  puts "INFO : == replacing repoURL in applications/app-*.yaml =="
  Dir.glob("#{work_dir}/applications/app-*.yaml").each do |file|
    next unless text_file?(file)
    original = File.read(file)
    content  = original.gsub(/^(\s*)repoURL:\s+.+$/, "\\1repoURL: #{local_repo_url}")
    if content != original
      puts "INFO : Replaced repoURL in: #{File.basename(file)}"
      File.write(file, content)
    end
  end
end

# ---- core sync ----

def sync_repo(mapping, to_version, dest_token)
  src_repo      = mapping["source"]["repo"]
  dst_repo      = mapping["destination"]["repo"]
  dst_branch    = mapping["destination"]["branch"]
  is_data_plane = mapping["is_data_plane"]
  transform     = mapping["transform"] || {}

  work_dir = nil
  src_tmp  = nil

  begin
    work_dir = "#{TEMP_DIR}/work-#{SecureRandom.hex(4)}"
    src_tmp  = "#{TEMP_DIR}/src-#{SecureRandom.hex(4)}"

    source_url     = build_url(SOURCE_TEMPLATE, src_repo)
    dest_url       = build_url(DEST_TEMPLATE, dst_repo, token: dest_token)
    local_repo_url = DEST_TEMPLATE.gsub("{repo}", dst_repo)

    puts "INFO : === Syncing #{src_repo}@#{to_version} → #{dst_repo} [#{dst_branch}] ==="

    # 1. Clone local git (destination) → workspace#1
    puts "INFO : Cloning local git (destination)..."
    run_cmd("git clone #{dest_url} #{work_dir}")
    run_cmd("git checkout #{dst_branch} || git checkout -b #{dst_branch}", work_dir)

    # 2. Clone remote git (source) at tag TO_VERSION → workspace#2
    puts "INFO : Cloning remote git at tag #{to_version}..."
    run_cmd("git clone #{source_url} #{src_tmp}")
    run_cmd("git checkout tags/#{to_version}", src_tmp)

    # 3. Verify version.txt matches TO_VERSION
    version_file = "#{src_tmp}/version.txt"
    raise "version.txt not found in #{src_repo}" unless File.exist?(version_file)

    actual_version = File.read(version_file).strip
    unless actual_version == to_version
      raise "version.txt mismatch in #{src_repo}: expected '#{to_version}', got '#{actual_version}'"
    end
    puts "INFO : version.txt verified: #{actual_version}"

    # 4. Copy workspace#2 → workspace#1 (exclude values-local.yaml)
    puts "INFO : Merging source into destination..."
    exclude_files = transform["exclude_files"] || []

    Dir.glob("#{src_tmp}/**/*", File::FNM_DOTMATCH).each do |path|
      next if path.include?("/.git")
      rel = path.sub("#{src_tmp}/", "")
      dst = File.join(work_dir, rel)

      if File.directory?(path)
        FileUtils.mkdir_p(dst)
      else
        FileUtils.mkdir_p(File.dirname(dst))
        if exclude_files.include?(File.basename(rel)) && File.exist?(dst)
          puts "INFO : Preserved: #{rel}"
          next
        end
        FileUtils.cp(path, dst)
      end
    end

    # 5. Data plane only: replace repoURL in applications/app-*.yaml → local Gitea URL
    replace_repo_url_in_app_yamls(work_dir, local_repo_url) if is_data_plane

    # 6. Commit and push back to local git
    run_cmd("git config user.email 'app-updater@local'", work_dir)
    run_cmd("git config user.name 'app-updater-bot'", work_dir)
    run_cmd("git add .", work_dir)

    stdout, _, _ = Open3.capture3("git status --porcelain", chdir: work_dir)
    if stdout.strip.empty?
      puts "INFO : Nothing to commit for #{src_repo}, skipping push"
      return
    end

    run_cmd("git commit -m 'upgrade #{src_repo} to #{to_version}'", work_dir)
    run_cmd("git remote set-url origin #{dest_url}", work_dir)
    run_cmd("git push origin #{dst_branch}", work_dir)
    puts "INFO : Successfully pushed #{src_repo} to local git"

  ensure
    FileUtils.rm_rf(work_dir) if work_dir
    FileUtils.rm_rf(src_tmp)  if src_tmp
  end
end

# ---- job status helpers ----

def update_job_failed(conn, job_id, message)
  conn.exec_params(
    "UPDATE \"Jobs\" SET status = 'Failed', failed_cnt = 1, job_message = $1, " \
    "end_date = CURRENT_TIMESTAMP, updated_date = CURRENT_TIMESTAMP WHERE job_id = $2",
    [message, job_id]
  )
end

# ---- main ----

skip_db = ENV['SKIP_DB'] == 'true'
conn    = nil

unless skip_db
  pgHost = ENV["PG_HOST"]
  pgDb   = ENV["PG_DB"]
  conn   = connect_db(pgHost, pgDb, ENV["PG_USER"], ENV["PG_PASSWORD"])
  if conn.nil?
    puts "ERROR : ### Unable to connect to PostgreSQL --> Host=[#{pgHost}], DB=[#{pgDb}] !!!"
    exit 101
  end
  puts "INFO : ### Connected to PostgreSQL [#{pgHost}] [#{pgDb}]"
end

jobId       = fallback(ENV['JOB_ID'], '')
fromVersion = ENV['FROM_VERSION']
toVersion   = ENV['TO_VERSION']

if toVersion.nil? || toVersion.strip.empty?
  puts "ERROR : TO_VERSION is required"
  exit 1
end

unless toVersion.start_with?('v')
  puts "ERROR : TO_VERSION must start with 'v' (got: #{toVersion})"
  exit 1
end

puts "INFO : ### Starting firmware upgrade: #{fromVersion} → #{toVersion}"

update_job_status(conn, jobId, 'Running') if conn && !jobId.empty?

dest_token = ENV['GIT_DEST_TOKEN']
CONFIG     = resolve_config(RAW_CONFIG)

begin
  FileUtils.mkdir_p(TEMP_DIR)

  CONFIG["mappings"].each do |mapping|
    sync_repo(mapping, toVersion, dest_token)
  end

  message = "Done upgrading from #{fromVersion} to #{toVersion}."
  update_job_done(conn, jobId, 1, 0, message) if conn && !jobId.empty?
  puts "INFO : ### #{message}"

rescue => e
  puts "ERROR : #{e.message}"
  puts e.backtrace.first(10).join("\n")

  error_msg = "Failed to upgrade to #{toVersion}: #{e.message}"
  update_job_failed(conn, jobId, error_msg) if conn && !jobId.empty?
  exit 1
end
