require "inotify"

class EdgeAI::ConfigChange
  Log = ::EdgeAI::Log.for("config.change")

  class_getter instance : ConfigChange { new }

  private def initialize
  end

  def on_change(&@on_change : String ->)
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
      @on_change.try &.call(File.read(PIPELINE_CONFIG))
    end
  end
end
