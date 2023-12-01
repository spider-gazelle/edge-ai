require "uuid"
require "./application"

# methods for viewing and updating the configuration of the device
class EdgeAI::Configuration < EdgeAI::Base
  base "/api/edge/ai"

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
  @[AC::Route::GET("/config")]
  def index : Array(Pipeline)
    PIPELINE_MUTEX.synchronize { PIPELINES.values }
  end

  # add a new video pipeline
  @[AC::Route::POST("/config", body: :pipeline, status_code: HTTP::Status::CREATED)]
  def create(pipeline : Pipeline) : Pipeline
    id = UUID.random.to_s
    save_config(id) do
      pipeline.id = id
      PIPELINES[id] = pipeline
    end
    pipeline
  end

  # view the current configuration
  @[AC::Route::GET("/config/:id")]
  def show(
    @[AC::Param::Info(description: "the id of the video stream", example: "ba714f86-cac6-42c7-8956-bcf5105e1b81")]
    id : String
  ) : Pipeline
    PIPELINE_MUTEX.synchronize { PIPELINES[id] }
  end

  # replace the configuration with new configuration
  @[AC::Route::PUT("/config/:id", body: :pipeline)]
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
  @[AC::Route::DELETE("/config/:id", status_code: HTTP::Status::ACCEPTED)]
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
      DetectionOutputs.instance.config_changed

      # close any streams watching this as the config has changed
      sockets = Monitor::STREAM_MUTEX.synchronize do
        socks = Monitor::STREAM_SOCKETS[id].dup
        Monitor::STREAM_SOCKETS.delete(id) if socks.empty?
        socks
      end
      sockets.each { |sock| sock.close }
    end
  end

  # this file is built as part of the docker build
  OPENAPI = YAML.parse(File.exists?("openapi.yml") ? File.read("openapi.yml") : "{}")

  # returns the OpenAPI representation of this service
  @[AC::Route::GET("/openapi")]
  def openapi : YAML::Any
    OPENAPI
  end
end
