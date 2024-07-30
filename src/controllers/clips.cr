require "./application"
require "file_utils"

class EdgeAI::Clips < EdgeAI::Base
  base "/api/edge/ai/clips"

  @[AC::Route::Filter(:before_action)]
  def find_configuration_config(
    @[AC::Param::Info(description: "the id of the video stream", example: "ba714f86-cac6-42c7-8956-bcf5105e1b81")]
    id : String? = nil
  ) : Nil
    return unless id

    existing = Configuration::PIPELINES[id]?
    raise AC::Error::NotFound.new("id #{id} does not exist") unless existing

    @id = id
    @config = existing
  end

  getter! id : String
  getter! config : Configuration::Pipeline

  # ============
  # Clip CRUD
  # ============

  record Metadata, timestamp : Int64, viewed : Bool, metadata : JSON::Any do
    include JSON::Serializable
    include YAML::Serializable
  end

  # list clips saved on the device, optionally filtering by stream id
  @[AC::Route::GET("/?:id")]
  def index : Array(String) | Array(Metadata)
    errors = [] of String

    if id = @id
      return [] of Metadata unless File.directory?(File.join(CLIP_PATH, id))

      Dir.glob(File.join(CLIP_PATH, id, "*.json")).compact_map { |filename|
        begin
          Metadata.from_json File.read(filename)
        rescue error
          errors << filename
          Log.warn(exception: error) { "reading clip metadata: #{filename}" }
          nil
        end
      }.sort! { |a, b| b.timestamp <=> a.timestamp }
    else
      # only return directories that don't include a . character
      Dir.entries(CLIP_PATH).reject! { |path| path.includes?('.') || !File.directory?(File.join(CLIP_PATH, path)) }
    end
  end

  # download the clip specified by the timestamp
  @[AC::Route::GET("/:id/:timestamp")]
  def show(
    @[AC::Param::Info(description: "the timestamp of the clip to download", example: "123456")]
    timestamp : Int64
  )
    # check video exists
    video_file = clip_path timestamp, "ts"
    raise AC::Error::NotFound.new("timestamp does not exist") unless File.exists?(video_file)

    # mark video as viewed if currently unviewed
    metadata_file = clip_path timestamp, "json"
    if File.exists?(metadata_file)
      begin
        meta = Metadata.from_json File.read(metadata_file)
        write_metadata(metadata_file, meta.timestamp, meta.metadata, true) unless meta.viewed
      rescue error
        Log.warn(exception: error) { "reading clip metadata: #{metadata_file}" }
        nil
      end
    end

    # download the file
    File.open(video_file) do |file|
      response.content_type = "video/mp2t"
      response.headers["Content-Disposition"] = %(attachment; filename="#{File.basename(video_file)}")
      @__render_called__ = true
      IO.copy(file, context.response)
    end
  end

  @[AC::Route::GET("/:id/:timestamp/thumbnail")]
  def thumbnail(
    @[AC::Param::Info(description: "the timestamp of the thumbnail to display", example: "123456")]
    timestamp : Int64
  )
    # check thumbnail exists
    thumbnail_file = clip_path timestamp, "jpg"
    raise AC::Error::NotFound.new("timestamp does not exist") unless File.exists?(thumbnail_file)

    # download the file
    File.open(thumbnail_file) do |file|
      response.content_type = "image/jpeg"
      response.headers["Content-Disposition"] = "inline"
      @__render_called__ = true
      IO.copy(file, context.response)
    end
  end

  # save a new clip to the device with the associated JSON payload
  @[AC::Route::POST("/:id", status_code: HTTP::Status::CREATED, body: :payload)]
  def create(
    payload : JSON::Any,
    @[AC::Param::Info(description: "the number of seconds to grab before now", example: "3")]
    seconds_before : UInt32 = 3_u32,
    @[AC::Param::Info(description: "the number of seconds to grab after now", example: "3")]
    seconds_after : UInt32 = 3_u32
  ) : Metadata
    timestamp = Time.utc.to_unix_ms
    time_str = timestamp.to_s
    meta_file = clip_path time_str, "json"
    video_file = clip_path time_str, "ts"
    thumbnail_file = clip_path time_str, "jpg"

    FileUtils.mkdir_p(File.join(CLIP_PATH, id))

    replay(video_parts_path, seconds_before.seconds, seconds_after.seconds) do |_file, name|
      begin
        File.rename(name, video_file)
      rescue
        Log.info { "move failed, copying clip" }
        File.copy(name, video_file)
      end
    end

    save_thumbnail(video_file, thumbnail_file, seconds_before)
    write_metadata(meta_file, timestamp, payload)
  end

  # delete a clip from storage
  @[AC::Route::DELETE("/:id/:timestamp", status_code: HTTP::Status::ACCEPTED)]
  def destroy(
    @[AC::Param::Info(description: "the timestamp of the clip to delete", example: "123456")]
    timestamp : Int64
  ) : Nil
    time_str = timestamp.to_s
    meta_file = clip_path time_str, "json"
    video_file = clip_path time_str, "ts"
    thumbnail_file = clip_path time_str, "jpg"

    File.delete? video_file
    File.delete? thumbnail_file
    File.delete? meta_file
  end

  # ============
  # video replay
  # ============

  # obtains a clip of the event
  @[AC::Route::GET("/:id/replay")]
  def replay(
    @[AC::Param::Info(description: "the number of seconds to grab before now", example: "3")]
    seconds_before : UInt32 = 3_u32,
    @[AC::Param::Info(description: "the number of seconds to grab after now", example: "3")]
    seconds_after : UInt32 = 3_u32
  ) : Nil
    replay(video_parts_path, seconds_before.seconds, seconds_after.seconds) do |file, _name|
      response.content_type = "video/mp2t"
      response.headers["Content-Disposition"] = %(attachment; filename="#{File.basename(file.path)}")
      @__render_called__ = true
      IO.copy(file, context.response)
    end
  end

  protected def clip_path(timestamp : Int64 | String, ext : String) : String
    File.join CLIP_PATH, id, "#{timestamp}.#{ext}"
  end

  protected def write_metadata(filename : String, timestamp : Int64, payload : JSON::Any, viewed : Bool = false) : Metadata
    metadata = Metadata.new(timestamp, viewed, payload)
    File.write filename, metadata.to_json
    metadata
  end

  alias Config = TensorflowLite::Pipeline::Configuration

  protected def video_parts_path
    replay_mount = REPLAY_MOUNT_PATH

    input = config.input
    case input
    in Config::InputStream, Config::InputDevice
      replay_mount / id
    in Config::InputImage
      raise "images don't support replays"
    in Config::Input
      raise "abstract class matched..."
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
        yield file, output_file
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

  def save_thumbnail(video_in : String, image_out : String, midpoint : Int) : Nil
    status = Process.run("ffmpeg", {
      "-ss", midpoint.to_s, "-i", video_in, "-frames:v", "1",
      "-q:v", "2", "-vf", "select=eq(pict_type\\,I)", "-vsync", "vfr",
      "-update", "1", image_out,
    }, error: :inherit, output: :inherit)

    Log.error { "failed to save video thumbnail" } unless status.success?
  end
end
