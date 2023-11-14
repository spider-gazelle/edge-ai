require "./application"

class EdgeAI::Monitor < EdgeAI::Base
  base "/api/edge/ai/monitor"

  # ========================
  # video stream connections
  # ========================

  STREAM_MUTEX   = Mutex.new
  STREAM_SOCKETS = Hash(String, Array(HTTP::WebSocket)).new do |hash, key|
    hash[key] = [] of HTTP::WebSocket
  end

  # pushes the video stream down the websocket
  @[AC::Route::WebSocket("/stream/?:id")]
  def stream(
    socket,
    @[AC::Param::Info(description: "the id of the video stream", example: "ba714f86-cac6-42c7-8956-bcf5105e1b81")]
    id : String
  )
    existing = Configuration::PIPELINES[id]?
    raise AC::Error::NotFound.new("id #{id} does not exist") unless existing

    STREAM_MUTEX.synchronize do
      STREAM_SOCKETS[id] << socket
    end

    socket.on_close do
      STREAM_MUTEX.synchronize do
        STREAM_SOCKETS[id].delete socket
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
  @[AC::Route::WebSocket("/detections/?:id")]
  def detect(
    socket,
    @[AC::Param::Info(description: "the id of the video stream", example: "ba714f86-cac6-42c7-8956-bcf5105e1b81")]
    id : String
  )
    existing = Configuration::PIPELINES[id]?
    raise AC::Error::NotFound.new("id #{id} does not exist") unless existing

    DETECT_MUTEX.synchronize { DETECT_SOCKETS[id] << socket }

    socket.on_close do
      DETECT_MUTEX.synchronize do
        sockets = DETECT_SOCKETS[id]
        sockets.delete socket
        DETECT_SOCKETS.delete(id) if sockets.empty?
      end
    end
  end

  # ============
  # video replay
  # ============

  # obtains a clip of the event
  @[AC::Route::GET("/replay/?:index")]
  def replay(
    @[AC::Param::Info(description: "the id of the video stream", example: "ba714f86-cac6-42c7-8956-bcf5105e1b81")]
    id : String,
    @[AC::Param::Info(description: "the number of seconds to grab before now", example: "3")]
    seconds_before : UInt32 = 3_u32,
    @[AC::Param::Info(description: "the number of seconds to grab after now", example: "3")]
    seconds_after : UInt32 = 3_u32
  ) : Nil
    # TODO::
  end
end
