require "option_parser"
require "./constants"
require "./models/*"

class EdgeAI::Processor
  alias Pipeline = TensorflowLite::Pipeline::Configuration::Pipeline

  def initialize
    @pipelines = if File.exists?(PIPELINE_CONFIG)
                   NamedTuple(pipelines: Hash(String, Pipeline)).from_yaml(File.read(PIPELINE_CONFIG))[:pipelines]
                 else
                   File.write EdgeAI::PIPELINE_CONFIG, %({"pipelines": {}})
                   {} of String => Pipeline
                 end
  end

  @shutdown : Bool = false

  # ========================
  # Configuration management
  # ========================

  @pipelines : Hash(String, Pipeline)

  def monitor_config
    ConfigChange.instance.on_change do |file_data|
      begin
        Log.info { "config update detected" }
        puts "config update detected"
        update_config NamedTuple(pipelines: Hash(String, Pipeline)).from_yaml(file_data)[:pipelines]
      rescue error
        Log.warn(exception: error) { "failed to apply configuration change" }
      end
    end
  end

  def update_config(pipelines : Hash(String, Pipeline))
    new_keys = pipelines.keys
    old_keys = @pipelines.keys

    # streams that were disabled
    removed = old_keys - new_keys
    if removed.size > 0
      Log.info { "removing #{removed.size} detection streams" }
      removed.each do |id|
        stop_stream id
      end
    end

    # add any new streams
    added = new_keys - old_keys
    added.each do |id|
      start_stream pipelines[id]
    end

    # find any with changes
    pipelines.each do |id, new_config|
      if old_config = @pipelines[id]?
        next if old_config.updated == new_config.updated
        Log.info { "stream config updated: #{id}" }

        stop_stream(id)
        start_stream(new_config)
      end
    end

    @pipelines = pipelines
  end

  # ========================
  # Pipeline management
  # ========================

  alias Coordinator = TensorflowLite::Pipeline::Coordinator

  @coordinators : Hash(String, Coordinator) = {} of String => Coordinator
  @signals : Hash(String, DetectionSignal) = {} of String => DetectionSignal

  def start_streams
    @pipelines.each_value do |stream|
      start_stream stream
    end
  end

  def stop_stream(id : String)
    Log.info { "stopping stream #{id}" }
    coord = @coordinators.delete id
    signal = @signals.delete id
    coord.try &.shutdown
    signal.try &.shutdown
  end

  def start_stream(config : Pipeline)
    return if @shutdown

    id = config.id.as(String)
    Log.info { "starting stream: #{id}" }

    coord = Coordinator.new(id, config)
    signal = DetectionSignal.new(id)

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
    spawn { coord.run_pipeline }
  end

  def shutdown
    @shutdown = true
    Log.info { "shutting down!" }
    @pipelines.each_key do |id|
      stop_stream id
    end
  end
end

::Log.setup("*", :info)

processor = EdgeAI::Processor.new
processor.start_streams
processor.monitor_config

channel = Channel(Nil).new

terminate = Proc(Signal, Nil).new do |signal|
  puts " > terminating gracefully"
  spawn do
    processor.shutdown
    channel.close
  end
  signal.ignore
end

# Detect ctr-c to shutdown gracefully
# Docker containers use the term signal
Signal::INT.trap &terminate
Signal::TERM.trap &terminate

channel.receive?
