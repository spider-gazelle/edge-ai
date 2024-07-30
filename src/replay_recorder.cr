require "./constants"
require "tflite_pipeline"
require "./models/stream_replay"
require "./models/config_change"

class EdgeAI::ReplayRecorder
  alias Pipeline = TensorflowLite::Pipeline::Configuration::Pipeline
  alias Config = TensorflowLite::Pipeline::Configuration

  def initialize
    @config = ConfigChange.instance
  end

  @shutdown : Bool = false

  # ========================
  # Configuration management
  # ========================

  def monitor_config
    @config.on_start_pipeline { |id, pipeline| record_replay(id, pipeline) }
    @config.on_stop_pipeline { |id| stop_recording id }
    @config.watch
  end

  # ===========================
  # Replay Recording Management
  # ===========================

  # pipeline id => process
  @processes : Hash(String, StreamReplay) = {} of String => StreamReplay

  def record_replay(id : String, pipeline : Pipeline) : Nil
    return if @shutdown

    replay = StreamReplay.new(id)
    input = pipeline.input
    task = uninitialized StreamReplay::BackgroundTask

    case input
    in Config::InputStream
      task = replay.start_replay_capture(input.path)
    in Config::InputDevice
      multicast_address = Socket::IPAddress.new(input.multicast_ip, input.multicast_port)
      task = replay.start_replay_capture("udp://#{multicast_address.address}:#{multicast_address.port}?overrun_nonfatal=1")
    in Config::InputImage, Config::Input
      # no capture available for this
      return
    end
    @processes[id] = replay

    # ensure it restarts if not ready or crashes
    spawn do
      task.on_exit.receive?
      task_running = @processes[id]?
      if !@shutdown && task_running && !task_running.shutdown_requested?
        sleep 1
        record_replay(id, pipeline)
      end
    end
  end

  def stop_recording(id : String)
    if replay = @processes.delete id
      replay.stop_capture
    end
    Log.info { "Recording stopped: #{id}" }
  end

  def shutdown
    @shutdown = true
    Log.info { "shutting down!" }
    @processes.each_key { |id| stop_recording id }
  end
end

::Log.setup("*", :info)

# start monitoring here
replay = EdgeAI::ReplayRecorder.new
replay.monitor_config

# Shutdown gracefully
channel = Channel(Nil).new
Process.on_terminate do
  puts " > terminating gracefully"
  spawn do
    replay.shutdown
    channel.close
  end
end
channel.receive?
