require "socket"

class EdgeAI::DetectionSignal
  Log = ::EdgeAI::Log.for("detection.signal")

  def initialize(@stream : String)
    @path = "./detections/#{@stream}.sock"
    spawn { start_server }
  end

  getter stream : String
  getter path : String

  @connections : Array(UNIXSocket) = [] of UNIXSocket
  @server : UNIXServer? = nil
  @mutex : Mutex = Mutex.new

  protected def start_server
    path = @path
    File.delete(path) rescue nil

    server = UNIXServer.new(path)
    @server = server

    while client = server.accept?
      @mutex.synchronize { @connections << client }
      Log.info { "client connected: #{path} (#{client.object_id.to_s(16)})" }
    end
  rescue error
    Log.error(exception: error) { "failed to start detection signal server" }
  end

  def send(payload : String)
    connections = @mutex.synchronize { @connections.dup }
    connections.each do |client|
      begin
        client.puts(payload)
      rescue error
        Log.trace { "client lost: #{@path} (#{client.object_id.to_s(16)})" }
        @mutex.synchronize { @connections.delete(client) }
      end
    end
  end

  def shutdown
    @server.try &.close
    File.delete(@path) rescue nil
  end
end
