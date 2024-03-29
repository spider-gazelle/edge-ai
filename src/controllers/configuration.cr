require "uuid"
require "./application"

# methods for viewing and updating the configuration of the device
class EdgeAI::Configuration < EdgeAI::Base
  base "/api/edge/ai/config"

  alias Pipeline = TensorflowLite::Pipeline::Configuration::Pipeline

  PIPELINE_MUTEX = Mutex.new
  PIPELINES      = begin
    if File.exists?(PIPELINE_CONFIG)
      NamedTuple(pipelines: Hash(String, Pipeline)).from_yaml(File.read(PIPELINE_CONFIG))[:pipelines]
    else
      {} of String => Pipeline
    end
  rescue error
    puts "Error reading #{PIPELINE_CONFIG}: #{error.inspect_with_backtrace}"
    {} of String => Pipeline
  end

  # view the current configuration
  @[AC::Route::GET("/")]
  def index : Array(Pipeline)
    PIPELINE_MUTEX.synchronize { PIPELINES.values }
  end

  # add a new video pipeline
  @[AC::Route::POST("/", body: :pipeline, status_code: HTTP::Status::CREATED)]
  def create(pipeline : Pipeline) : Pipeline
    id = UUID.random.to_s
    save_config(id) do
      pipeline.id = id
      PIPELINES[id] = pipeline
    end
    pipeline
  end

  # clear the current configurations
  @[AC::Route::POST("/clear")]
  def clear_all : Array(String)
    ids = PIPELINE_MUTEX.synchronize { PIPELINES.keys }
    ids.each { |id| destroy(id) }
    ids
  end

  # view the current configuration
  @[AC::Route::GET("/:id")]
  def show(
    @[AC::Param::Info(description: "the id of the video stream", example: "ba714f86-cac6-42c7-8956-bcf5105e1b81")]
    id : String
  ) : Pipeline
    PIPELINE_MUTEX.synchronize { PIPELINES[id] }
  end

  # replace the configuration with new configuration
  @[AC::Route::PUT("/:id", body: :pipeline)]
  def update(
    @[AC::Param::Info(description: "the id of the video stream", example: "ba714f86-cac6-42c7-8956-bcf5105e1b81")]
    id : String,
    pipeline : Pipeline
  ) : Pipeline
    save_config(id) do
      existing = PIPELINES[id]?
      raise AC::Error::NotFound.new("index #{id} does not exist") unless existing

      pipeline.id = id
      PIPELINES[id] = pipeline
    end
    pipeline
  end

  # remove a pipeline from the device
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy(
    @[AC::Param::Info(description: "the id of the video stream", example: "ba714f86-cac6-42c7-8956-bcf5105e1b81")]
    id : String
  ) : Nil
    save_config(id) { PIPELINES.delete id }
  end

  protected def save_config(id : String, &)
    PIPELINE_MUTEX.synchronize do
      yield
      File.write(PIPELINE_CONFIG, {pipelines: PIPELINES}.to_yaml)
      DetectionReaders.instance.config_changed

      # close any streams watching this as the config has changed
      sockets = Monitor::STREAM_MUTEX.synchronize do
        socks = Monitor::STREAM_SOCKETS[id].dup
        Monitor::STREAM_SOCKETS.delete(id) if socks.empty?
        socks
      end
      sockets.each(&.close)
    end
  end
end
