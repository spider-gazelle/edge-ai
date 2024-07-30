require "option_parser"
require "./constants"
require "./models/*"
require "tasker"

class EdgeAI::Processor
  alias Pipeline = TensorflowLite::Pipeline::Configuration::Pipeline

  def initialize
    @config = ConfigChange.instance
  end

  @shutdown : Bool = false

  # ========================
  # Configuration management
  # ========================

  def monitor_config
    @config.on_start_pipeline { |id, _pipeline| start_process id }
    @config.on_stop_pipeline { |id| stop_process id }
    @config.watch
  end

  # ========================
  # Process management
  # ========================

  alias BackgroundTask = TensorflowLite::Pipeline::BackgroundTask

  # stream_id => process
  @processes : Hash(String, BackgroundTask) = {} of String => BackgroundTask

  def start_process(id : String) : Nil
    return if @shutdown

    Log.info { "Process starting: #{id}" }
    process_path = Process.executable_path.as(String)
    task = BackgroundTask.new
    task.run process_path, "-s", id
    @processes[id] = task

    # restart the container if there was a crash
    # only way to ensure child ffmpeg processes are not left dangling
    #
    # TODO:: once clip recorder is in place, restart just the process
    # if it using an external stream
    # We could probably refactor so clip recorder does all the work
    # * external stream => save recordings
    # * hardware => dummy => stream => recordings
    # then in both cases we can restart just the child process
    spawn do
      task.on_exit.receive?
      task_running = @processes[id]?
      if !@shutdown && task_running && task_running.on_exit.closed?
        exit(-1)
      end
    end
  end

  def stop_process(id : String) : Nil
    Log.info { "Process stopping: #{id}" }
    if task = @processes.delete id
      task.close
    end
  end

  # ========================
  # Pipeline management
  # ========================

  alias Coordinator = TensorflowLite::Pipeline::Coordinator

  @motion_detection : Hash(String, Motion) = {} of String => Motion
  @coordinators : Hash(String, Coordinator) = {} of String => Coordinator
  @signals : Hash(String, DetectionWriter) = {} of String => DetectionWriter

  # def start_streams
  #  @config.pipelines.each_key do |id|
  #    start_stream id
  #  end
  # end

  def stop_stream(id : String)
    coord = @coordinators.delete id
    motion = @motion_detection.delete id
    motion.try &.shutdown

    signal = @signals.delete id
    if signal
      Log.info { "stopping stream #{id}" }
      coord.try &.shutdown
      signal.shutdown
    end
  end

  class MotionState
    def initialize
      @running = false
      @debounce = Time.utc
    end

    property running : Bool
    property debounce : Time
  end

  def start_stream(id : String)
    return if @shutdown

    config = @config.pipelines[id]?
    return unless config

    Log.info { "starting stream: #{id}" }

    coord = Coordinator.new(id, config)
    signal = DetectionWriter.new(id)

    @coordinators[id] = coord
    @signals[id] = signal

    coord.on_output do |_, detections, stats|
      processing_time = stats.average_milliseconds
      signal.send({
        fps:        stats.fps(processing_time),
        avg_time:   processing_time,
        detections: detections,
      }.to_json)
    end

    if motion_config = config.motion_detector
      motion = Motion.new(**motion_config)
      @motion_detection[id] = motion

      state = MotionState.new
      trigger_output = config.motion_trigger_output.group_by { |io|
        io[:chip]
      }.flat_map do |chip, lines|
        gpio = GPIO::Chip.new chip
        lines.map do |io|
          line_num = io[:line]
          line = gpio.line(line_num)
          line.request_output
          line
        end
      end

      motion.on_motion do
        now = Time.utc
        next if state.running || state.debounce > now

        # switch on USB port and/or IR lights
        trigger_output.each(&.set_high)

        # start the
        state.running = true
        spawn { coord.run_pipeline }
        schedule_shutdown(config, coord, motion, state, trigger_output)
      end
    else
      spawn { coord.run_pipeline }
    end
  end

  protected def schedule_shutdown(config, coord, motion, state, trigger_output)
    Tasker.in(config.motion_active_seconds.seconds) do
      # is motion still being detected
      if motion.detected
        schedule_shutdown(config, coord, motion, state, trigger_output)
      else
        coord.shutdown
        state.debounce = config.motion_debounce_seconds.seconds.from_now
        state.running = false
        trigger_output.each(&.set_low)
      end
    end
  end

  def shutdown
    @shutdown = true
    Log.info { "shutting down!" }
    @config.pipelines.each_key { |id| stop_stream id }
    @processes.each_key { |id| stop_process(id) }
  end
end

require "tflite_pipeline"

stream_id = nil
OptionParser.parse(ARGV.dup) do |parser|
  parser.banner = "Manages the AI pipelines based on the config file"

  parser.on("-s STREAM", "--stream=STREAM", "Specifies the stream this process should pipeline") do |stream|
    stream_id = stream
  end
end

::Log.setup("*", :info)

if stream_id
  # start processing the pipeline
  processor = EdgeAI::Processor.new
  processor.start_stream stream_id.as(String)
else # this is the management process
  # ensure a config file exists
  File.write EdgeAI::PIPELINE_CONFIG, %({"pipelines": {}}) unless File.exists?(EdgeAI::PIPELINE_CONFIG)

  # start child processes
  processor = EdgeAI::Processor.new
  processor.monitor_config
end

# Shutdown gracefully
channel = Channel(Nil).new
Process.on_terminate do
  puts " > terminating gracefully"
  spawn do
    processor.shutdown
    channel.close
  end
end
channel.receive?
