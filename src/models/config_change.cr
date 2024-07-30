require "inotify"
require "./pipeline"

class EdgeAI::ConfigChange
  Log = ::EdgeAI::Log.for("config.change")

  alias Pipeline = TensorflowLite::Pipeline::Configuration::Pipeline

  class_getter instance : ConfigChange { new }

  private def initialize
  end

  getter pipelines : Hash(String, Pipeline) { read_config }

  @mutex : Mutex = Mutex.new

  def on_stop_pipeline(&@stop_pipeline : String ->)
  end

  def on_start_pipeline(&@start_pipeline : String, Pipeline ->)
  end

  def watch
    if !File.exists?(PIPELINE_CONFIG)
      Log.trace { "creating config file: #{PIPELINE_CONFIG}" }
      dir = File.dirname(PIPELINE_CONFIG)
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
      File.write PIPELINE_CONFIG, %({"pipelines": {}})
    end

    watched_file = File.expand_path(PIPELINE_CONFIG)
    Log.trace { "watching file: #{watched_file}" }

    Inotify.watch(PIPELINE_CONFIG) do |event|
      Log.info { "new config change event: #{event}" }
      spawn { new_config }
    end

    # apply the config
    new_config
  end

  def read_config : Hash(String, Pipeline)
    NamedTuple(pipelines: Hash(String, Pipeline)).from_yaml(File.read(PIPELINE_CONFIG))[:pipelines]
  rescue error
    Log.warn(exception: error) { "failed to read configuration file, applying default" }
    {} of String => Pipeline
  end

  def new_config
    @mutex.synchronize do
      pipelines = read_config
      # ensure old pipelines are configured
      @pipelines ||= {} of String => Pipeline
      apply_changes pipelines
    end
  rescue error
    Log.warn(exception: error) { "failed to apply configuration change" }
  end

  def apply_changes(pipelines : Hash(String, Pipeline))
    new_keys = pipelines.keys
    old_keys = self.pipelines.keys
    @pipelines = pipelines

    # streams that were disabled
    removed = old_keys - new_keys
    if removed.size > 0
      Log.info { "removing #{removed.size} pipelines" }
      removed.each { |id| stop_pipeline(id) }
    end

    # add any new streams
    added = new_keys - old_keys
    added.each { |id| start_pipeline(id, pipelines[id]) }

    # find any with changes
    pipelines.each do |id, new_config|
      if old_config = self.pipelines[id]?
        next if old_config.updated == new_config.updated
        Log.info { "stream config updated: #{id}" }

        stop_pipeline(id)
        sleep 1
        start_pipeline(id, new_config)
      end
    end
  end

  def start_pipeline(id : String, pipeline : Pipeline)
    Log.info { "pipeline starting: #{id}" }
    @start_pipeline.try &.call(id, pipeline)
  rescue error
    Log.warn(exception: error) { "error starting pipeline #{id}" }
  end

  def stop_pipeline(id : String)
    Log.info { "pipeline stopping: #{id}" }
    @stop_pipeline.try &.call(id)
  rescue error
    Log.warn(exception: error) { "error stopping pipeline #{id}" }
  end
end
