#!/usr/bin/env ruby

require 'rubygems'
require 'eventmachine'
require 'net/http'
require 'cgi'
require 'uri'
require 'thread'

 module ProxyServer
   def post_init
     puts "Connection opened"
   end

   def receive_data data
      response = ProxyResponder.new(data)
     send_data response
     close_connection_after_writing 
   end

     def unbind
       puts 'Connection closed'
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
      lines.delete_if{|line|
        matches = line.match(/^([^:]+): (.*)/)
        @headers[matches[1].capitalize] = matches[2] if matches and matches[1] and matches[2]
        matches and matches[1] and matches[2]
      }
      lines.each{|line|
        @data.push line if line.strip != ""
      }
  end
  def self.parseCookies(cookieStr="")
        cookieHash = Hash.new()
        cookieStr.split("; ").each{|cookie|
            cookie = cookie.split(", ").each{|sub_cookie|
                sub_cookie = sub_cookie.split("=")
                cookieHash[sub_cookie[0]]  = sub_cookie[1]
            }
        }
        cookieHash
   end
end


class ProxyResponder
   def fetch
        http = Net::HTTP.start(real_host(host))
        response = http.request_get(path, headers_to_send) unless client_response.method == "POST"
        response = http.request_post(path,client_response.data.join("\r\n"), headers_to_send) if client_response.method == "POST"
      http.finish
        response
   end
   def real_host(host)
        @@host_lookup_table.fetch(host, host)
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
   
   def save_host?
      if client_response.path.match(/^\/http:\/\//) and client_response.method != "POST":
        true
      else 
        false 
      end
   end
   
   def server_host
       unless @server_host :
            @server_host = "#{@@host}:#{@@port}"
            @server_host = client_response.headers["Host"] if client_response.headers["Host"]
       end
       @server_host
   end
   
   def client_response
    @client_response || @client_response = HTTPResponse.new(@data)
   end
   
   def headers_to_send
        headers_to_send = client_response.headers
        headers_to_send.each {|x, y|
            y.gsub!(server_host, host)
        }
        headers_to_send.delete_if {|x, y| x == "Accept-encoding"}
        headers_to_send
   end
   
   def cookies
    @cookies || @cookies = HTTPResponse.parseCookies(client_response.headers["Cookie"]) if client_response.headers["Cookie"]
   end
   
   def code 
    @code || @code = "200 OK"
   end
   
   def path
        path = url
        path = "#{uri.path}" if uri.path and uri.host
        path = "#{uri.path}?#{uri.query}" if uri.query and uri.path and uri.host
        path = "/" if path == ""
        path
   end
   
   def url
         url = "/"
         url = client_response.path.gsub(/^\/http:\/\//, 'http://') if client_response.path
         url.gsub!(/^\/nocache\//, "")
         
         url
   end
   
   def host 
    host = ""
    host = cookies["host"] if cookies and cookies["host"]
    host = uri.host if uri.host
    host
   end
   
   def uri
    URI.parse(url)
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
            value.gsub!(host, server_host)
            unless header == "Content-Type" || header == "Host" || header == "Connection" || header == "Keep-Alive" || header == "Content-Length" || header == "Cache-Control" || header == "Set-Cookie":
               extra << "#{header}: #{value}\r\n"
            end
          }
         generateHTTP(buf, @code, res.header["Content-type"], extra) 
         end
   
   def initialize(data)
   #uncomment this so the server does not crash on errors but instead shows a 500 error
    begin
         @response = ""
         @data = data
         if save_host?:
            @response = generateHTTP("", "301 Moved Permanently", "text/html", "Set-Cookie: host=#{host}; path=/; expires=0\r\nLocation: #{path}") 
         else 
            @response = proxy_response
         end
      rescue => e
         @response = generateHTTP("#{e}", "500 Server Error", "text/html")
      end
      end
end

@@host_lookup_table = {"www.mhfh.com" => "72.233.77.194", "mhfh.com" => "72.233.77.194"}
@@host = "127.0.0.1"
@@port = 80

 EventMachine::run {
   EventMachine::start_server @@host, @@port, ProxyServer
 }