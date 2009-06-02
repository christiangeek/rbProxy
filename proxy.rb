#!/usr/bin/env ruby

require 'rubygems'
require 'eventmachine'
require 'net/http'
require 'net/https'
require 'cgi'
require 'uri'
require 'thread'
require 'ruby-debug'

HOST_LOOKUP_TABLE = {"www.mhfh.com" => "72.233.77.194", "mhfh.com" => "72.233.77.194"}
HOST = "127.0.0.1"
PORT = 3000

module ProxyServer
  CONNECTION_OPENED = "Connection opened".freeze
  CONNECTION_CLOSED = "Connection closed".freeze  

  def self.start
    EventMachine::run { EventMachine::start_server(HOST, PORT, self) }
  end
  
  def post_init
    puts CONNECTION_OPENED
  end

  def receive_data(data)
    response = ProxyResponder.new(data)
    send_data response.to_s
    close_connection_after_writing
  end

  def unbind
    puts CONNECTION_CLOSED
  end
end


class HTTPResponse
  attr_accessor :method, :path, :code, :headers, :data
  
  def initialize(response_str)
    lines = response_str.split("\r\n")
    first_line = lines.slice!(0)
    first_line = first_line.split(" ")
    
    @method = first_line[0]
    @path = first_line[1]
    @code = first_line[2]
    @headers = Hash.new
    @data = Array.new
    
    lines.delete_if do |line|
      matches = line.match(/^([^:]+): (.*)/)
      @headers[matches[1].capitalize] = matches[2] if matches and matches[1] and matches[2]
      matches and matches[1] and matches[2]
    end
    
    lines.each {|line| @data.push line if line.strip != "" }
  end
  
  def self.parseCookies(cookieStr="")
    cookieHash = Hash.new()
    cookieStr.split("; ").each do |cookie|
      cookie = cookie.split(", ").each do |sub_cookie|
        sub_cookie = sub_cookie.split("=")
        cookieHash[sub_cookie[0]]  = sub_cookie[1]
      end
    end
    cookieHash
  end

  def protocol
    @path.gsub(/^\/http(s)?:\/\//, 'http\1://')
  end
  
  def save_host?
    if https? and post?
      true
    else
      false
    end
  end
  
  def https?
    @path.match(/^\/https?:\/\//)
  end
  
  def post?
    @method == "POST"
  end
  
  def post_data
    @data.join("\r\n")
  end
end


class ProxyResponder
  
  def initialize(data)
    begin
      @data = data
      @response = (client_response.save_host?) ? generate_301 : proxy_response
    # rescue => e
    #   @response = generateHTTP("#{e}", "500 Server Error", "text/html")
    end
  end

  def generate_301
    generateHTTP("", "301 Moved Permanently", "text/html", "Set-Cookie: rbProxy_host=#{host}; path=/; expires=0\r\nSet-Cookie: rbProxy_secure=#{is_secure?}; path=/; expires=0\r\nLocation: #{path}")
  end
  
  def fetch
    http_connection do |http|
      client_response.post? ? http.request_post(path, client_response.post_data, headers_to_send) : http.request_get(path, headers_to_send)
    end
  end

  def http_init
    unless is_secure?
      http = new_http(80) 
    else 
      http = http_secure_init
    end
    http
  end
  
  def http_secure_init
    http = new_http(443) 
    http.use_ssl = true 
  end
  
  def new_http(port)
    Net::HTTP.new(real_host(host), port) 
  end
  
  def http_connection(&block)
    http = http_init
    begin
      http.start
      yield(http)
    ensure
      http.finish
    end
      
  end
  
  def real_host(host)
    HOST_LOOKUP_TABLE.fetch(host, host)
  end
  
  def generateHTTP(content="", code="200 OK", type="text/html", extra="")
    str = ""
    str << "HTTP/1.0 #{code}\r\n"
    str << "Content-type: #{type}\r\n"
    str << "#{extra}" if extra != ""
    str << "\r\n"
    str << content if content
    str
  end
  
  def to_s
    @response
  end

  def server_host
    unless @server_host
      @server_host = "#{HOST}:#{PORT}"
      @server_host = client_response.headers["Host"] if client_response.headers["Host"]
    end
    @server_host
  end

  def client_response
    @client_response ||= HTTPResponse.new(@data)
  end

  def headers_to_send
    headers_to_send = client_response.headers
    headers_to_send.each {|x, y| y.gsub!(server_host, host)}
    headers_to_send.delete_if {|x, y| x == "Accept-encoding" || x == "If-modified-since"}
    headers_to_send
  end

  def cookies
    @cookies ||= HTTPResponse.parseCookies(client_response.headers["Cookie"]) if client_response.headers["Cookie"]
  end

  def code
    @code ||= "200 OK"
  end

  def path
    path = url
    path = "#{uri.path}" if uri.path and uri.host
    path = "#{uri.path}?#{uri.query}" if uri.query and uri.path and uri.host
    path = "/" if path == ""
    path
  end

  def url
    url = (client_response.path) ? client_response.protocol : "/"
    url.gsub!(/^\/nocache\//, "") || url
  end

  def is_secure?
    (cookies && cookies["rbProxy_secure"] == "true") || uri.scheme == "https" 
  end

  def host
    host = ""
    host = cookies["rbProxy_host"] if cookies and cookies["rbProxy_host"]
    host = uri.host if uri.host
    host
  end

  def uri
    @uri ||= URI.parse(url)
  end

  def proxy_response
    res = fetch
    buf = ""
    buf = res.body if res.body

    if res.header["Content-type"] and (res.header["Content-type"].include?("text") || res.header["Content-type"].include?("application"))
      buf.gsub!("http://", '/nocache/http://')
      script = '<script>function rbProxy_changeLinks() {var rbProxy_as = document.getElementsByTagName("a"); for ( var rbProxy_i=0, rbProxy_len=rbProxy_as.length; rbProxy_i<rbProxy_len; ++rbProxy_i ){ rbProxy_as[rbProxy_i].href = rbProxy_as[rbProxy_i].href.replace(/\/nocache/,""); } var rbProxy_forms = document.getElementsByTagName("form"); for ( var rbProxy_i=0, rbProxy_len=rbProxy_forms.length; rbProxy_i<rbProxy_len; ++rbProxy_i ){ rbProxy_forms[rbProxy_i].action = rbProxy_forms[rbProxy_i].action.replace(/\/nocache/,""); }var rbProxy_inputs = document.getElementsByTagName("input"); for ( var rbProxy_i=0, rbProxy_len=rbProxy_inputs.length; rbProxy_i<rbProxy_len; ++rbProxy_i ){ rbProxy_inputs[rbProxy_i].value = rbProxy_inputs[rbProxy_i].value.replace(/\/nocache\//,""); }} rbProxy_changeLinks(); setInterval ( "rbProxy_changeLinks()", 1000 );</script>'
      buf.gsub!("</body>", "#{script}</body>")
      buf = buf+script if buf.include?("<body") and !buf.include?("</body>")
    end

    begin
      res.value
    rescue => e
      @code = e.to_s.gsub('"', '')
    end
    
    extra = "Cache-Control: : max-age=30, no-cache\r\n"
    res.header.each_capitalized{|header, value|
      value.gsub!("http://", '/http://') if header == "Location"
      if header == "Set-Cookie":
        #value.gsub!(/ ([^=]+)=([^;]+); path=\/([^,]+),/, ' %RB_pr|\3%\1=\2; path=/,')
        #p value
        values = value.split(", ")
        values.each{|sub_value|

          sub_value.gsub!(/, $/, "")
          #p sub_value
          extra << "Set-Cookie: #{sub_value}\r\n"
        }
      end
      value.gsub!(host, server_host) unless header == "Location"
      unless header == "Content-Type" || header == "Host" || header == "Connection" || header == "Keep-Alive" || header == "Content-Length" || header == "Cache-Control" || header == "Set-Cookie" || header == "Transfer-Encoding":
        extra << "#{header}: #{value}\r\n"
      end
    }
    generateHTTP(buf, code, res.header["Content-type"], extra)
  end

end

ProxyServer.start