require "./application"

class EdgeAI::Status < EdgeAI::Base
  base "/api/edge/ai"

  # status of all configured pipelines
  @[AC::Route::GET("/status")]
  def index : Hash(String, PipelineStatus)
    keys = Configuration::PIPELINE_MUTEX.synchronize { Configuration::PIPELINES.keys }
    status = {} of String => PipelineStatus
    keys.each { |id| status[id] = get_status(id) }
    status
  end

  # status of the specified pipeline
  @[AC::Route::GET("/status/:id")]
  def show(
    @[AC::Param::Info(description: "the id of the video stream", example: "ba714f86-cac6-42c7-8956-bcf5105e1b81")]
    id : String
  ) : PipelineStatus
    existing = Configuration::PIPELINE_MUTEX.synchronize do
      # ensure the stream still exists
      Configuration::PIPELINES[id]?
    end
    raise AC::Error::NotFound.new("stream #{id} was removed") unless existing

    get_status id
  end

  def get_status(id : String) : PipelineStatus
    PipelineStatus.from_yaml File.read(File.join(PIPELINE_STATUS, "#{id}.yml"))
  rescue error
    Log.warn(exception: error) { "issue reading status file" }
    PipelineStatus.new(status_available: false)
  end

  # this file is built as part of the docker build
  OPENAPI = YAML.parse(File.exists?("openapi.yml") ? File.read("openapi.yml") : "{}")

  # returns the OpenAPI representation of this service
  @[AC::Route::GET("/openapi")]
  def openapi : YAML::Any
    OPENAPI
  end
end
