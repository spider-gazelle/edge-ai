require "json"
require "yaml"

class PipelineStatus
  include JSON::Serializable
  include YAML::Serializable

  # hash of subsystem => issue description
  property errors : Hash(String, String) = {} of String => String
  property warnings : Hash(String, String) = {} of String => String

  property? status_available : Bool = true
  property last_updated : Time

  def initialize(@status_available = true, @errors = {} of String => String, @warnings = {} of String => String)
    @last_updated = Time.utc
  end
end
