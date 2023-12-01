require "tflite_pipeline"

# monkey patches the notification configuration into the pipeline configuration
class TensorflowLite::Pipeline::Configuration::Pipeline
  getter id : String? = nil
  getter description : String? = nil
  property updated : Time? = nil

  def id=(uuid : String)
    @id = uuid
    @updated = Time.local
  end

  property webhook_uri : String? = nil

  # ws, tcp, host, port
  property mqtt_uri : String? = nil
end
