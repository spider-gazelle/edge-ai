require "socket"

class EdgeAI::DetectionReaders
  Log = ::EdgeAI::Log.for("detection.outputs")

  class_getter instance : DetectionReaders { new }

  private def initialize
    # Private constructor to prevent external instantiation
    Dir.mkdir_p("./detections") unless Dir.exists?("./detections")
    spawn { ensure_connected }
  end

  getter connected_count : Int32 = 0
  getter? running : Bool = true

  @streams : Hash(String, UNIXSocket) = {} of String => UNIXSocket
  @changed = Channel(Nil).new(1)

  def config_changed
    @changed.send nil
  end

  def shutdown : Nil
    @running = false
    @changed.close
  end

  protected def ensure_connected
    loop do
      pipelines = Configuration::PIPELINE_MUTEX.synchronize { Configuration::PIPELINES.dup }
      pipeline_keys = pipelines.keys
      stream_keys = @streams.keys

      # remove excess streams
      removed = stream_keys - pipeline_keys
      if removed.size > 0
        Log.info { "removing #{removed.size} detection streams" }
        removed.each do |id|
          @streams.delete(id).try &.close
        end
      end

      # reconnect any dropped sockets
      @streams.each do |id, existing_socket|
        if existing_socket.closed?
          if new_socket = connect_to(id)
            @streams[id] = new_socket
          end
        end
      end

      # add any new streams
      added = pipeline_keys - stream_keys
      added.each do |id|
        if socket = connect_to(id)
          @streams[id] = socket
        end
      end

      # wait for new data
      select
      when @changed.receive?
        Log.trace { "checking for detection changes [notify]" }
      when timeout(5.seconds)
        Log.trace { "checking for detection changes [timeout]" }
      end
      break unless @running
    end

    # cleanup
    Log.trace { "closing detection sockets" }
    @streams.each_value(&.close)
  rescue error
    Log.error(exception: error) { "error connecting to detection unix sockets" }
  end

  protected def connect_to(id : String) : UNIXSocket?
    path = "./detections/#{id}.sock"
    socket = UNIXSocket.new(path)
    spawn { process_detection(id, socket) }
    Log.info { "connected to: #{path}" }
    socket
  rescue Socket::ConnectError
    Log.warn { "connection failed to: #{path}" }
  rescue error
    Log.warn(exception: error) { "connection failed to: #{path}" }
    nil
  end

  # send detection data to the websockets
  protected def process_detection(id, socket)
    socket.each_line do |string|
      ws_list = Monitor::DETECT_MUTEX.synchronize { Monitor::DETECT_SOCKETS[id].dup }
      ws_list.each { |ws| ws.send(string) rescue nil }
    end
  rescue e : IO::Error
  rescue error
    Log.warn(exception: error) { "socket processing error" }
  ensure
    socket.close
  end
end
