require "./application"

class EdgeAI::Monitor < EdgeAI::Base
  base "/api/edge/ai/monitor"

  @[AC::Route::Filter(:before_action)]
  def find_configuration_config(
    @[AC::Param::Info(description: "the id of the video stream", example: "ba714f86-cac6-42c7-8956-bcf5105e1b81")]
    id : String
  )
    existing = Configuration::PIPELINES[id]?
    raise AC::Error::NotFound.new("id #{id} does not exist") unless existing

    @id = id
    @config = existing
  end

  getter! id : String
  getter! config : Configuration::Pipeline

  # ========================
  # video stream connections
  # ========================

  STREAM_MUTEX   = Mutex.new
  STREAM_SOCKETS = Hash(String, Array(HTTP::WebSocket)).new do |hash, key|
    hash[key] = [] of HTTP::WebSocket
  end
  STREAM_PLAYBACK = Hash(String, ConfidenceMonitor).new

  def self.stream_to_sockets(monitor : ConfidenceMonitor)
    monitor.on_receive do |id, bytes|
      socks = STREAM_MUTEX.synchronize { STREAM_SOCKETS[id].dup }
      socks.each(&.send(bytes))
    end
  end

  # pushes the video stream down the websocket
  @[AC::Route::WebSocket("/:id/stream")]
  def stream(socket)
    Configuration::PIPELINE_MUTEX.synchronize do
      # ensure the stream still exists
      existing = Configuration::PIPELINES[id]?
      raise AC::Error::NotFound.new("stream #{id} was removed") unless existing

      # track the websocket
      STREAM_MUTEX.synchronize do
        STREAM_SOCKETS[id] << socket

        # start stream if not already running
        streaming = STREAM_PLAYBACK[id]?
        if streaming.nil?
          STREAM_PLAYBACK[id] = mon = ConfidenceMonitor.new(id, existing)
          self.class.stream_to_sockets(mon)
        end
      end
    end

    socket.on_close do
      STREAM_MUTEX.synchronize do
        sockets = STREAM_SOCKETS[id]
        sockets.delete socket
        if sockets.empty?
          STREAM_SOCKETS.delete id
          stream = STREAM_PLAYBACK.delete id
          stream.try &.shutdown
        end
      end
    end
  end

  # ==========================
  # detection tracking sockets
  # ==========================

  DETECT_MUTEX   = Mutex.new
  DETECT_SOCKETS = Hash(String, Array(HTTP::WebSocket)).new do |hash, key|
    hash[key] = [] of HTTP::WebSocket
  end

  # pushes detections found in the video stream in realtime to connected sockets
  @[AC::Route::WebSocket("/:id/detections")]
  def detect(socket)
    DETECT_MUTEX.synchronize { DETECT_SOCKETS[id] << socket }

    socket.on_close do
      DETECT_MUTEX.synchronize do
        sockets = DETECT_SOCKETS[id]
        sockets.delete socket
        DETECT_SOCKETS.delete(id) if sockets.empty?
      end
    end
  end
end
