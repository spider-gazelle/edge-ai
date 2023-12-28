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
  @[AC::Route::WebSocket("/stream/:id")]
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
  @[AC::Route::WebSocket("/detections/:id")]
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

  # ============
  # video replay
  # ============

  # obtains a clip of the event
  @[AC::Route::GET("/replay/:id")]
  def replay(
    @[AC::Param::Info(description: "the number of seconds to grab before now", example: "3")]
    seconds_before : UInt32 = 3_u32,
    @[AC::Param::Info(description: "the number of seconds to grab after now", example: "3")]
    seconds_after : UInt32 = 3_u32
  ) : Nil
    replay_mount = TensorflowLite::Pipeline::Coordinator::REPLAY_MOUNT_PATH

    input = config.input
    path = case input
           in TensorflowLite::Pipeline::Configuration::InputStream
             replay_mount / id
           in TensorflowLite::Pipeline::Configuration::InputDevice
             replay_mount / Path[input.path].stem
           in TensorflowLite::Pipeline::Configuration::InputImage
             raise "images don't support replays"
           in TensorflowLite::Pipeline::Configuration::Input
             raise "abstract class matched..."
           end

    replay(path, seconds_before.seconds, seconds_after.seconds) do |file|
      response.content_type = "video/mp2t"
      response.headers["Content-Disposition"] = %(attachment; filename="#{File.basename(file.path)}")
      @__render_called__ = true
      IO.copy(file, context.response)
    end
  end

  def replay(path : Path, before : Time::Span, after : Time::Span, & : File ->)
    created_after = before.ago
    sleep after # wait for future files to be generated

    file_list = File.tempname("replay", ".txt")
    output_file = File.tempname("replay", ".ts")
    begin
      construct_replay(path, file_list, output_file, created_after)
      File.open(output_file) do |file|
        yield file
      end
    ensure
      File.delete? output_file
      File.delete? file_list
    end
  end

  protected def construct_replay(path : Path, file_list : String, output_file : String, created_after : Time) : Nil
    files = Dir.entries(path).select do |file|
      next if {".", ".."}.includes?(file)
      file = File.join(path, file)

      begin
        info = File.info(file)
        !info.size.zero? && info.modification_time >= created_after
      rescue File::NotFoundError
        nil
      rescue error
        puts "Error obtaining file info for #{file}\n#{error.inspect_with_backtrace}"
        nil
      end
    end

    # ensure the files are joined in the correct order
    files.map! { |file| File.join(path, file) }.sort! do |file1, file2|
      info1 = File.info(file1)
      info2 = File.info(file2)
      info1.modification_time <=> info2.modification_time
    end

    # generate a list of files to be included in the output
    raise "no replay files found..." if files.size.zero?
    File.open(file_list, "w") do |list|
      files.each { |file| list.puts("file '#{file}'") }
    end

    # concat the files
    status = Process.run("ffmpeg", {
      "-f", "concat", "-safe", "0",
      "-i", file_list, "-c", "copy",
      output_file,
    }, error: :inherit, output: :inherit)

    raise "failed to save video replay" unless status.success?
  end
end
