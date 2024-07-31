require "tflite_pipeline"

class EdgeAI::StreamReplay
  alias BackgroundTask = TensorflowLite::Pipeline::BackgroundTask

  # this process captures chunks of video so we can generate replays
  def initialize(id : String)
    @replay_store = REPLAY_MOUNT_PATH / id
    configure_ram_drive if REPLAY_CONFIGURE_RAMDISK
  end

  @replay_task : BackgroundTask? = nil
  @replay_store : Path
  @replay_mutex : Mutex = Mutex.new

  getter? shutdown_requested : Bool = false

  def start_replay_capture(stream : String)
    # ensure the folder exists
    Dir.mkdir_p @replay_store

    @replay_task = task = BackgroundTask.new
    filenames = File.join(@replay_store, "output_%Y%m%d%H%M%S.ts")
    task.run(
      "ffmpeg",
      "-i", stream,
      "-c", "copy", "-copyinkf", "-an", "-map", "0", "-f",
      "segment", "-segment_time", "2", "-loglevel", "warning",
      "-reset_timestamps", "1", "-strftime", "1", filenames
    )

    spawn { cleanup_old_files }
    task
  end

  def stop_capture
    @shutdown_requested = true
    @replay_task.try &.close
  end

  protected def cleanup_old_files : Nil
    loop do
      sleep 11.seconds
      break if @replay_task.try(&.on_exit.closed?)
      expired_time = 180.seconds.ago

      @replay_mutex.synchronize do
        files = Dir.entries(@replay_store)
        Log.info { "Checking #{files.size} files for removal" }

        files.each do |file|
          begin
            next if {".", ".."}.includes?(file)
            file = File.join(@replay_store, file)
            File.delete(file) if File.info(file).modification_time < expired_time
          rescue error
            Log.error(exception: error) { "Error checking removal of #{file}" }
          end
        end
      end
    end
  end

  # ram drive for saving replays
  # really here to document what needs to be configured on the OS at boot
  protected def configure_ram_drive
    output = IO::Memory.new
    status = Process.run("mount", output: output)
    raise "failed to check for existing mount" unless status.success?

    # NOTE:: this won't work in production running as a low privileged user
    # sudo mkdir -p /mnt/ramdisk
    # sudo mount -t tmpfs -o size=512M tmpfs /mnt/ramdisk
    if !String.new(output.to_slice).includes?(REPLAY_MOUNT_PATH.to_s)
      Dir.mkdir_p REPLAY_MOUNT_PATH
      status = Process.run("mount", {"-t", "tmpfs", "-o", "size=#{REPLAY_MEM_SIZE}", "tmpfs", REPLAY_MOUNT_PATH.to_s})
      raise "failed to mount ramdisk: #{REPLAY_MOUNT_PATH}" unless status.success?
    end
  end

  def replay(before : Time::Span, after : Time::Span, & : File ->)
    raise "replay not available" unless @replay_task

    created_after = before.ago
    sleep after # wait for future files to be generated

    file_list = File.tempname("replay", ".txt")
    output_file = File.tempname("replay", ".ts")
    begin
      replay_file = @replay_mutex.synchronize do
        construct_replay(file_list, output_file, created_after)
      end
      yield replay_file
    ensure
      File.delete? output_file
      File.delete? file_list
    end
  end

  protected def construct_replay(file_list : String, output_file : String, created_after : Time) : File
    files = Dir.entries(@replay_store).select do |file|
      next if {".", ".."}.includes?(file)
      file = File.join(@replay_store, file)

      begin
        info = File.info(file)
        !info.size.zero? && info.modification_time >= created_after
      rescue e : File::NotFoundError
        nil
      rescue error
        puts "Error obtaining file info for #{file}\n#{error.inspect_with_backtrace}"
        nil
      end
    end

    # ensure the files are joined in the correct order
    files.map! { |file| File.join(@replay_store, file) }.sort! do |file1, file2|
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

    File.new(output_file)
  end
end
