require "option_parser"
require "v4l2"

OptionParser.parse(ARGV.dup) do |parser|
  parser.banner = "Usage: #{PROGRAM_NAME} [arguments]"

  parser.on("-d", "--devices", "List the devices available with their formats and resolutions") do
    Dir.glob("/dev/video*").each do |dev_path|
      begin
        path = Path[dev_path]
        video = V4L2::Video.new(path)
        begin
          details = video.device_details
          dummy = details.card.downcase.includes?("dummy")
          formats = video.supported_formats
          next if formats.empty? && !dummy

          puts String.build { |str|
            str << "\n* "
            str << path

            if dummy
              str << "\n  Loopback device"
            else
              str << "\n  "
              str << details.card
              str << " ("
              str << details.driver
              str << ")"

              formats.each do |pixel|
                str << "\n  - "
                str << pixel.code
                pixel.frame_sizes.each do |size|
                  rate = size.frame_rate
                  str << "\n    "
                  rate.width.to_s(str)
                  str << "x"
                  rate.height.to_s(str)
                  str << " ("
                  rate.fps.round(1).to_s(str)
                  str << "fps) ["
                  str << size.type
                  str << "]"
                end
              end
            end
          }
        ensure
          video.close
        end
      rescue error
        puts "* #{dev_path} (#{error.message})"
      end
    end
  end

  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit 0
  end
end
