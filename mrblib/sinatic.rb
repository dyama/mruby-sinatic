module Sinatic
  @content_type = nil
  @options = {:host => '127.0.0.1', :port => 8888}
  @routes = { 'GET' => [], 'POST' => [] }
  @shutdown = false
  def self.route(method, path, opts, &block)
    @routes[method] << [path, opts, block]
  end
  def self.content_type(type)
    @content_type = type
  end
  def self.set(key, value)
    @options[key] = value
  end
  def code2mesg(code)
    case code
    when 200 ; "OK"
    when 404 ; "Not found"
    else     ; "Internal Server Error"
    end
  end
  def response_header(code, type, content)
    ar = []
    ar.push "HTTP/1.0 #{code} #{code2mesg(code)}"
    if code == 200
      ar.push "Content-Type: #{type}"
    end
    ar.push "Content-Length: #{content.size}"
    ar.push ""
    ar.push ""
    ar.join("\r\n") + content
  end
  def self.do(r)
    route = @routes[r.method].select {|path|
      if path[0].class.to_s == 'String'
        path[0] == r.path
      else
        /#{path[0]}/ =~ r.path
      end
    }
    if route.size > 0
      param = {}
      if r.headers['Content-Type'] == 'application/x-www-form-urlencoded'
        r.body.split('&').each do |x|
          tokens = x.split('=', 2)
          if tokens && tokens.size == 2
            param[tokens[0]] = HTTP::URL::decode(tokens[1])
          end
        end
      end
      @content_type = 'text/html; charset=utf-8'
      bb = route[0][2].call(r, param)
      if bb.class.to_s == 'Array'
        bb = bb[0]
      end
      return 200, [
        "HTTP/1.0 200 OK",
        "Content-Type: #{@content_type}",
        "Content-Length: #{bb.size}",
        "", ""].join("\r\n") + bb
    end
    if r.method == 'GET' && r.path
      f = nil
      begin
        file = r.path + (r.path[-1] == '/' ? 'index.html' : '')
        ext = file.split(".")[-1]
        ctype = ['txt', 'html', 'css'].index(ext) ? "text/" + ext :
                ['js'].index(ext) ? "text/javascript" :
                 'application/octet-stream'
        f = UV::FS::open("public#{file}", UV::FS::O_RDONLY, UV::FS::S_IREAD)
        bb = ''
        while (read = f.read(4096, bb.size)).size > 0
          bb += read
        end
        return 200, [
            "HTTP/1.0 200 OK",
            "Content-Type: #{ctype}; charset=utf-8",
            "Content-Length: #{bb.size}",
            "", ""].join("\r\n") + bb
      rescue => ex
        p ex
        # 404
      ensure
        f.close if f
      end
    end
    return 404, response_header(404, "plain/text", code2mesg(404))
  end
  def self.shutdown?
    @shutdown
  end
  def self.shutdown
    @shutdown = true
  end
  def self.run(options = {})
    s = UV::TCP.new
    config = {:host => @options[:host], :port => @options[:port].to_i}.merge(options)
    s.bind(UV::ip4_addr(config[:host], config[:port]))
    s.listen(2000) do |x|
      return if x != 0 or s == nil
      begin
        c = s.accept
        c.data = ''
      rescue
        return
      end
      c.read_start do |b|
        begin
          raise RuntimeError unless b
          c.data += b
          i = c.data.index("\r\n\r\n")
          if i != nil && i >= 0
            r = HTTP::Parser.new.parse_request(c.data)
            r.body = c.data.slice(i + 4, c.data.size - i - 4)
            if !r.headers.has_key?('Content-Length') || r.headers['Content-Length'].to_i == r.body.size
              code, bb = ::Sinatic.do(r)
              if !r.headers.has_key?('Connection') || r.headers['Connection'].upcase != 'KEEP-ALIVE'
                c.write(bb) do |x|
                  c.close if c && !c.closing?
                  c = nil
                end
              else
                c.write(bb)
                c.data = ''
              end
            end
          end
        rescue => ex
          msg = ex.to_s
          c.write("HTTP/1.0 500 Internal Server Error\r\nContent-Length: #{msg.size}\r\n\r\n#{msg}") do |x|
            c.close if c && !c.closing?
            c = nil
          end
	  puts msg
        end
      end
    end

    t = UV::Timer.new
    t.data = s
    t.start(3000, 3000) do |x|
      if Sinatic.shutdown?
        t.data.close
        t.data = nil
        t.close
        t = nil
      end
      UV::gc
    end

    UV::run
  end
end

module Kernel
  def get(path, opts={}, &block)
    ::Sinatic.route 'GET', path, opts, &block
  end
  def post(path, opts={}, &block)
    ::Sinatic.route 'POST', path, opts, &block
  end
  def content_type(type)
    ::Sinatic.content_type type
  end
  def set(key, value)
    ::Sinatic.set key, value
  end
end

# vim: set fdm=marker:
