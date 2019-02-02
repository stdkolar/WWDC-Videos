# Have fun. Use at your own risk.
# Copyright (c) 2017 Johannes Fahrenkrug

require 'rubygems'
require 'fileutils'
require 'net/http'
require 'uri'

begin
  require 'json'
rescue LoadError => e
  puts
  puts "You need to have the json gem installed."
  puts "Install it by running"
  puts
  puts "  bundle install"
  puts
  puts "and then run the script like this:"
  puts
  puts "  bundle exec ruby lib/wwdcdownloader.rb"
  puts
  exit
end

class WWDCDownloader
  BASE_URI = 'https://devimages-cdn.apple.com/wwdc-services/h8a19f8f/049CCC2F-0D8A-4F7D-BAB9-2D8F5BAA7030/contents.json'

  WWDC_LIBRARIES = [{:base => 'https://developer.apple.com/library/content', :lib => '/navigation/library.json'}]

  attr_accessor :downloaded_files, :dl_dir, :min_date, :proxy_uri

  def initialize(dl_dir, min_date)
    self.dl_dir = dl_dir
    self.min_date = min_date
    self.downloaded_files = []
    self.proxy_uri = nil

    if ENV['http_proxy'] || ENV['HTTP_PROXY']
      uri = (ENV['http_proxy']) ? ENV['http_proxy'] : ENV['HTTP_PROXY']
      self.proxy_uri = URI.parse(uri)
    end
  end

  # Creates the given directory if it doesn't exist already.
  def mkdir(dir)
    if File.directory?(dir)
      false
    else
      Dir.mkdir dir
      true
    end
  end

  def read_url(url)
    uri = URI.parse(url)

    http = nil

    if self.proxy_uri
      http = Net::HTTP.new(uri.host, uri.port, self.proxy_uri.host, self.proxy_uri.port, self.proxy_uri.user, self.proxy_uri.password)
    else
      http = Net::HTTP.new(uri.host, uri.port)
    end

    http.use_ssl = true

    http.start do |http|
     request = Net::HTTP::Get.new(uri.request_uri)
     response = http.request(request)

     if response.code == '200'
       yield(response.body)
     end
   end
  end

  def download_sample_code_from_book_json(book_json_url, code_base_url, dest_dir, duplicates_ok)
    did_download = false
    self.read_url(book_json_url) do |book_json|
      if book_json[0,1] == '<'
        puts " Sorry, this samplecode apparently isn't available yet: #{code_base_url}/book.json"
      else
        book_res = JSON.parse(book_json)
        filename = book_res["sampleCode"]
        url = "#{code_base_url}/#{filename}"

        did_download = download_file(url, filename, dest_dir, duplicates_ok)
      end
    end

    did_download
  end

  def download_file(url, filename, dest_dir, duplicates_ok = true)
    did_download = false
    outfilename = dest_dir + "/" + filename
    if duplicates_ok or (!File.exists?(outfilename) and !self.downloaded_files.include?(url))
      # remember what we downloaded
      self.downloaded_files << url

      puts "  Downloading #{url}"
      begin
        self.read_url(url) do |downloaded_file|
          open(outfilename, 'wb') do |file|
            file.write(downloaded_file)
          end
          did_download = true
        end
      rescue Exception => e
        puts "  Download failed #{e}"
      end
    elsif !duplicates_ok
      puts "  Already downloaded this file, skipping."
    end

    did_download
  end

  def load
    mkdir(dl_dir)

    # get the sessions JSON
    self.read_url(BASE_URI) do |body|
      res = JSON.parse(body)

      sessions = res['contents']
      resources = res['resources']

      if sessions.size > 0

        sessions.each do |session|
          if session['type'] == 'Session' && session['eventId'] == 'wwdc2017'
            title = session['title']
            session_id = session['id'].gsub('wwdc2017-', '')
            puts "Session #{session_id} '#{title}'..."

            if session['related'] && session['related']['resources']
              # Iterate over the resources
              related_resource_ids = session['related']['resources']
              did_download = false

              # get the files
              dirname = "#{dl_dir}/#{session_id}-#{title.gsub(/\/|&|!/, '')}"
              puts "  Creating #{dirname}"
              did_create_dir = mkdir(dirname)

              resources.each do |resource|
                if resource['resource_type'] == 'samplecode' && related_resource_ids.include?(resource['id'])
                  puts "  Found related resource #{resource['url']}"

                  # Zip file? download right away
                  if resource['url'] =~ /(\w+\.zip)$/
                    uri = URI.parse(resource['url'])
                    filename = File.basename(uri.path)

                    if download_file(resource['url'], filename, dirname, true)
                      did_download = true
                    end
                  # Sample code landing page?
                  else
                    # Sanitize URL
                    url = resource['url'].split('/Introduction/Intro.html')[0]

                    if download_sample_code_from_book_json("#{url}/book.json", url, dirname, false)
                      did_download = true
                    end
                  end
                end
              end

              if !did_download and did_create_dir
                Dir.delete(dirname)
              end
            end
          end
        end
      else
        print "No sessions :(.\n"
      end
    end

    # scrape the WWDC libraries...
    puts
    puts "Scraping the WWDC libraries..."
    WWDC_LIBRARIES.each do |lib_hash|
      lib = "#{lib_hash[:base]}#{lib_hash[:lib]}"
      puts
      puts "Library #{lib}"
      self.read_url(lib) do |body|
        body = body.gsub("''", '""')
        # Fix misformatted JSON
        body = body.gsub(/\"platform\"\s*:\s*12,$\s*\}/, "\"platform\": 12\n}")
        res = JSON.parse(body)

        docs = res['documents']

        if docs.size > 0
          docs.each do |doc|
            if doc[2] == 5 and doc[3] >= self.min_date # sample code and newer or equal to min date
              title = doc[0]

              puts "Sample Code '#{title}'..."

              # get the files
              dirname = "#{dl_dir}/#{title.gsub(/\/|&|!|:/, '')}"
              did_create_dir = mkdir(dirname)
              puts "  Created #{dirname}" if did_create_dir

              segments = doc[9].split('/')
              url = "#{lib_hash[:base]}/samplecode/#{segments[2]}/book.json"

              #puts url
              did_download = download_sample_code_from_book_json(url, "#{lib_hash[:base]}/samplecode/#{segments[2]}", dirname, false)
              if !did_download and did_create_dir
                Dir.delete( dirname )
              end
            end
          end
        else
          print "No code samples :(.\n"
        end
      end
    end

    puts "Done."
  end

  def self.run!(*args)
    puts "WWDC 2017 Session Material Downloader"
    puts "by Johannes Fahrenkrug, @jfahrenkrug, springenwerk.com"
    puts "See you next year!"
    puts
    puts "Usage: wwdcdownloader [<target-dir>]"
    puts

    dl_dir = if args.size == 1
      args.last
    else
      'wwdc2017-assets'
    end

    w = WWDCDownloader.new(dl_dir, '2017-06-01')
    w.load
    return 0
  end
end
