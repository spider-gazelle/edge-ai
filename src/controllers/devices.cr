require "./application"

# details of any devices that are connected to the system
class EdgeAI::Devices < EdgeAI::Base
  base "/api/edge/ai/devices"

  record Resolution, width : UInt32, height : UInt32, fps : Float64, type : V4L2::FrameSizeType do
    include JSON::Serializable
    include YAML::Serializable
  end

  record Format, code : String, resolutions : Array(Resolution) do
    include JSON::Serializable
    include YAML::Serializable
  end

  record VideoDevice, path : String, name : String, driver : String, formats : Array(Format) do
    include JSON::Serializable
    include YAML::Serializable
  end

  # list the devices available locally and their capabilities
  @[AC::Route::GET("/")]
  def index : Array(VideoDevice)
    Dir.glob("/dev/video*").compact_map do |dev_path|
      begin
        path = Path[dev_path]
        video = V4L2::Video.new(path)
        begin
          details = video.device_details
          dummy = details.card.downcase.includes?("dummy")
          formats = video.supported_formats
          next if formats.empty? || dummy

          VideoDevice.new(
            path: dev_path,
            name: details.card,
            driver: details.driver,
            formats: formats.map { |format|
              Format.new(
                code: format.code,
                resolutions: format.frame_sizes.map { |size|
                  rate = size.frame_rate
                  Resolution.new(
                    width: rate.width,
                    height: rate.height,
                    fps: rate.fps.round(1),
                    type: size.type
                  )
                }
              )
            }
          )
        ensure
          video.close
        end
      rescue error
        Log.error(exception: error) { "error reading #{dev_path}" }
        nil
      end
    end
  end
end
