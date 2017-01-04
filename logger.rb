#!/usr/bin/env ruby
require "fileutils"

$stdout.sync = true
$stderr .sync = true

LOG_PIPE_PATH = "/var/log/nginx/trace_request.pipe"

def main
  if File.exists?(LOG_PIPE_PATH)
    system("rm #{LOG_PIPE_PATH}")
  end
  FileUtils.mkdir_p("/var/log/nginx")
  system("mkfifo #{LOG_PIPE_PATH}")

  exit 1 if $?.exitstatus != 0

  # Start nginx
  if (nginx_pid= fork).nil?
    Kernel.exec("/usr/local/openresty/bin/openresty -c /etc/nginx/nginx.conf -g 'daemon off;'")
  end

  if (log_pid = fork).nil?
    do_log
  end

  loop do
    pid = Process.wait

    if pid == log_pid
      puts "Log process exited"
      exit $?.exitstatus
    end

    if pid == nginx_pid
      puts "Nginx process exited"
      exit $?.exitstatus
    end
  end
end


def do_log
  require 'timeout'
  require 'json'
  require 'thread'
  require 'uri'
  require 'net/http'
  require 'time'

  queue = Queue.new
  Thread.new { process_queue(queue) }

  buffer = ""
  File.open(LOG_PIPE_PATH) do |log_file|
    loop do #Indefinetly try to read from the log file
      buffer += log_file.readpartial(2048)
      loop do # Try to read a new line.
        line,new_buffer = buffer.split("\n",2)
        break if new_buffer.nil?
        buffer = line
        json = JSON.load(line) rescue nil
        if json
          queue.push json
        else
          puts "Could not parse json. Ignoring message:\n#{line}"
        end
        buffer = new_buffer
      end
    end
  end
end

def process_queue(queue)
  Thread.current.abort_on_exception = true
  loop do
    nginx_log_entry = queue.pop

    # Convert from whole seconds (as logged by nginx) to microseconds (which are expected by zipkin)
    duration = (nginx_log_entry["request_time"].to_f * 1000).to_i

    time  = Time.parse(nginx_log_entry["time"])
    timestamp = time.to_i * 1_000_000

    # See http://zipkin.io/zipkin-api/#/paths/%252Fspans
    message = [
        {
          traceId: nginx_log_entry["trace_id"],
          id: nginx_log_entry["trace_id"],
          name: "edge-router",
          duration: duration,
          timestamp: timestamp,
          parentId: nil,
          annotations: [
            { timestamp: timestamp, value: "cs", endpoint: { "serviceName": "edge-router" } }, # client starts
            { timestamp: timestamp + duration, value: "cr", endpoint: { "serviceName": "edge-router" } }, # client received
          ],
          binaryAnnotations: [
            { key: "request", value: nginx_log_entry["request"] },
            { key: "status", value: nginx_log_entry["status"] },
            { key: "request_method", value: nginx_log_entry["request_method"] },
            { key: "remote_addr", value: nginx_log_entry["remote_addr"] }
          ]
        }
    ]

    loop do
      begin
        push_zipkin_message(message)
        puts "pushed mesage to zipkin: #{message.inspect}"
        break
      rescue Exception => e
        puts "#{Time.now.to_s} Failed to push message to zipkin; #{e}"
        sleep 1
      end
    end
  end
end

def push_zipkin_message(message)
  uri = URI.parse("http://zipkin:9411/api/v1/spans")
  http = Net::HTTP.new(uri.host, uri.port)
#  http.use_ssl = true

  headers = {
    "Content-Type" => "application/json"
  }

  request = Net::HTTP::Post.new(uri.request_uri, headers)
  request.body = JSON.dump(message)
  response = http.request(request)

  if response.code != "202"
    puts "Did not get a 202 message"
    puts response.code
    puts response.body rescue nil
  end
end

main
