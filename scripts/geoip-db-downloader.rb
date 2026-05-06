#!/usr/bin/env ruby

require 'net/http'
require 'uri'
require 'json'
require 'fileutils'
require 'digest'
require 'open-uri'
require 'zlib'
require 'rubygems/package'
require 'time'

if File.exist?('env.rb')
  #Default environment variables
  require './env'
end

$stdout.sync = true

# Required ENV variables:
# TEMP_DIR=/tmp/maxmind
# DOWNLOAD_DIR=/data/mmdb
# LICENSE_KEY=xxxx
# EDITION_ID=GeoLite2-City

TMP_DIR = ENV.fetch('TEMP_DIR')
DOWNLOAD_DIR = ENV.fetch('DOWNLOAD_DIR')
LICENSE_KEY = ENV.fetch('LICENSE_KEY')
EDITION_ID = ENV.fetch('EDITION_ID')
CHECK_INTERVAL = 3600 # 1 hour

FileUtils.mkdir_p(TMP_DIR)
FileUtils.mkdir_p(DOWNLOAD_DIR)

BASE_URL = "https://download.maxmind.com/app/geoip_download?edition_id=#{EDITION_ID}&license_key=#{LICENSE_KEY}&suffix=tar.gz"
SHA_URL = "#{BASE_URL}.sha256"


def log(message)
  puts "[#{Time.now.utc.iso8601}] #{message}"
end

def fetch_remote_sha
  URI.open(SHA_URL).read.split.first.strip
end

def version_file_path
  File.join(DOWNLOAD_DIR, 'version.json')
end

def current_version
  return nil unless File.exist?(version_file_path)
  JSON.parse(File.read(version_file_path))
rescue
  nil
end

def download_file(url, output_path)
  URI.open(url) do |remote|
    File.open(output_path, 'wb') do |file|
      IO.copy_stream(remote, file)
    end
  end
end

def extract_tar_gz(archive_path, destination)
  FileUtils.rm_rf(destination)
  FileUtils.mkdir_p(destination)

  Zlib::GzipReader.open(archive_path) do |gz|
    Gem::Package::TarReader.new(gz) do |tar|
      tar.each do |entry|
        dest_file = File.join(destination, entry.full_name)

        if entry.directory?
          FileUtils.mkdir_p(dest_file)
        else
          FileUtils.mkdir_p(File.dirname(dest_file))
          File.open(dest_file, 'wb') do |f|
            f.write(entry.read)
          end
        end
      end
    end
  end
end

def find_mmdb_file(extract_dir)
  Dir.glob(File.join(extract_dir, '**', '*.mmdb')).first
end

def extract_release_date_from_folder(mmdb_path)
  # Example folder: GeoLite2-City_20260505
  match = mmdb_path.match(/_(\d{8})\//)
  match ? match[1] : Time.now.utc.strftime('%Y%m%d')
end

def sha256_of_file(path)
  Digest::SHA256.file(path).hexdigest
end

def atomic_copy(src, dest)
  temp_dest = "#{dest}.tmp"
  FileUtils.cp(src, temp_dest)
  FileUtils.mv(temp_dest, dest, force: true)
end

def update_version_file(metadata)
  File.write(
    version_file_path,
    JSON.pretty_generate(metadata)
  )
end

def cleanup_old_versions(current_filename, retain_count = 3)
  pattern = File.join(DOWNLOAD_DIR, "#{EDITION_ID}_*.mmdb")
  files = Dir.glob(pattern).sort.reverse

  files_to_delete = files.reject { |f| File.basename(f) == current_filename }.drop(retain_count - 1)

  files_to_delete.each do |file|
    begin
      File.delete(file)
      log("Deleted old version: #{File.basename(file)}")
    rescue => e
      log("Failed to delete old version #{file}: #{e.message}")
    end
  end
end

def perform_update
  remote_sha = fetch_remote_sha
  current = current_version

  if current && current['sha256'] == remote_sha
    log('No new MaxMind DB version available.')
    return
  end

  log("New version detected for #{EDITION_ID}. Downloading...")

  archive_path = File.join(TMP_DIR, "#{EDITION_ID}.tar.gz")
  extract_dir = File.join(TMP_DIR, "#{EDITION_ID}_extract")

  download_file(BASE_URL, archive_path)
  extract_tar_gz(archive_path, extract_dir)

  mmdb_file = find_mmdb_file(extract_dir)
  raise 'MMDB file not found after extraction.' unless mmdb_file

  release_date = extract_release_date_from_folder(mmdb_file)
  final_filename = "#{EDITION_ID}_#{release_date}.mmdb"
  final_path = File.join(DOWNLOAD_DIR, final_filename)

  actual_sha = sha256_of_file(mmdb_file)

  atomic_copy(mmdb_file, final_path)

  metadata = {
    edition_id: EDITION_ID,
    filename: final_filename,
    sha256: remote_sha,
    actual_file_sha256: actual_sha,
    release_date: release_date,
    downloaded_at: Time.now.utc.iso8601,
  }

  update_version_file(metadata)

  # Retain only latest 3 versions by default
  cleanup_old_versions(final_filename, 3)

  log("Successfully updated #{EDITION_ID} => #{final_filename}")
end

log("Starting MaxMind updater loop for #{EDITION_ID}")

loop do
  begin
    perform_update
  rescue => e
    log("Update failed: #{e.class} - #{e.message}")
    log(e.backtrace.first(5).join("\n"))
  end

  log("Sleeping for #{CHECK_INTERVAL} seconds...")
  sleep(CHECK_INTERVAL)
end
