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

  # motion sensor activation
  alias IOLine = NamedTuple(chip: String, line: Int32)
  property motion_detector : IOLine? = nil
  property motion_active_seconds : Int32 { 20 }
  property motion_debounce_seconds : Int32 { 3 }
  property motion_trigger_output : Array(IOLine) { [] of IOLine }
end
