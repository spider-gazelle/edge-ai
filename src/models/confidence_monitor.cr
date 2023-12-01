class ConfidenceMonitor
  alias Configuration = TensorflowLite::Pipeline::Configuration

  def initialize(@id : String, @config : Configuration::Pipeline)
    spawn { start_stream }
  end

  getter id : String
  getter config : Configuration::Pipeline
  @mutex : Mutex = Mutex.new
  getter running : Bool = true

  def shutdown
    @running = false
  end

  def closed?
    !@running
  end

  def on_receive(&@on_receive : (String, Bytes) ->)
  end

  def start_stream
    input = @config.input
    ip, port = case input
               when Configuration::InputStream
                 # TODO:: we convert this to mp4 ts for confidence and capture it
                 stream = input.path
                 return
               when Configuration::InputDevice
                 {input.multicast_ip, input.multicast_port}
               else # streaming not supported
                 return
               end

    multicast_address = Socket::IPAddress.new(ip, port)
    io = UDPSocket.new
    begin
      io.reuse_address = true
      io.reuse_port = true
      io.read_timeout = 3.seconds
      io.bind "0.0.0.0", multicast_address.port
      io.join_group(multicast_address)

      # largest packets seem to be 4096 * 15
      bytes = Bytes.new(4096 * 20)
      id = @id

      loop do
        break if closed? || io.closed?
        bytes_read, _client_addr = io.receive(bytes)
        break if bytes_read == 0

        @on_receive.try &.call(id, bytes[0, bytes_read].dup)
      end
    rescue error
      Log.warn(exception: error) { "error reading multicast stream" }
      io.close
      if !closed?
        sleep 1
        spawn { start_stream }
      end
    end
  end
end
