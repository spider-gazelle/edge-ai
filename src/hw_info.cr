require "tensorflow_lite/edge_tpu"
require "option_parser"
require "v4l2"
require "gpio"

show_help = true

parse = OptionParser.parse(ARGV.dup) do |parser|
  parser.banner = "Usage: #{PROGRAM_NAME} [arguments]"

  parser.on("-t", "--tensor", "List the coral.ai tensor accelerators available") do
    show_help = false

    puts "\nTensor Accelerators\n==================="
    TensorflowLite::EdgeTPU.devices.each do |dev|
      puts "* #{dev.type}"
      puts "  #{dev.path}"
    end
    puts ""
  end

  parser.on("-g", "--gpio", "List the General Purpose Input Output chips available") do
    show_help = false

    puts "\nGPIO Chips\n==================="
    Dir.glob("/dev/gpiochip*").sort! do |path|
      chip = GPIO::Chip.new(Path[path])
      puts "* #{chip.name} (#{chip.label})"
      puts "  path:  #{path}"
      puts "  lines: #{chip.num_lines}"
    end
    puts ""
  end

  parser.on("-v", "--video", "List the video devices available with their formats and resolutions") do
    show_help = false

    puts "\nVideo Hardware\n=============="
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
    show_help = true
  end
end

puts parse if show_help
