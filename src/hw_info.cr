require "tensorflow_lite"
require "tensorflow_lite/edge_tpu"
require "option_parser"
require "http"
require "v4l2"
require "gpio"

show_help = true

gpu_test = {
  {input: {0.0_f32, 0.0_f32}, result: 0},
  {input: {1.0_f32, 0.0_f32}, result: 1},
  {input: {0.0_f32, 1.0_f32}, result: 1},
  {input: {1.0_f32, 1.0_f32}, result: 0},
}

tpu_test = {
  {input: {-128_i8, -128_i8}, result: 0},
  {input: {127_i8, -128_i8}, result: 1},
  {input: {-128_i8, 127_i8}, result: 1},
  {input: {127_i8, 127_i8}, result: 0},
}

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

  parser.on("--test-tpu=INDEX", "tensorflow coral.ai delegate testing") do |index|
    show_help = false
    puts "TPU Delegate Test\n================="

    if delegate = TensorflowLite::EdgeTPU.devices[index.to_i]?.try(&.to_delegate)
      puts "  downloading model..."
      client = TensorflowLite::Client.new(
        URI.parse("https://raw.githubusercontent.com/spider-gazelle/tensorflow_lite/main/spec/test_data/xor_model_quantized_edgetpu.tflite"),
        delegate: delegate
      )

      puts "  running test..."
      tpu_test.each do |test|
        inputs = test[:input]
        expected = test[:result]

        # configure inputs
        ints = client[0].as_i8
        ints[0], ints[1] = inputs

        # run through NN
        client.invoke!

        # check results
        ints = client.output.as_i8
        result = ints[0] >= 0_i8 ? 1 : 0

        if result != expected
          puts "  test failed :("
          break
        end
      end

      puts "  test complete!"
    else
      puts "  no TPU at index #{index}, num devices #{TensorflowLite::EdgeTPU.devices.size}"
    end
  end

  parser.on("--test-gpu", "tensorflow gpu delegate testing") do
    show_help = false

    # it will fallback to CPU for this test if there is no hardware installed
    puts "\nGPU Delegate Test\n================="
    puts "  downloading model..."
    client = TensorflowLite::Client.new(
      URI.parse("https://raw.githubusercontent.com/spider-gazelle/tensorflow_lite/main/spec/test_data/xor_model.tflite"),
      delegate: TensorflowLite::DelegateGPU.new
    )

    puts "  running test..."
    gpu_test.each do |test|
      inputs = test[:input]
      expected = test[:result]

      # configure inputs
      floats = client[0].as_f32
      floats[0], floats[1] = inputs

      # run through NN
      client.invoke!

      # check results
      floats = client.output.as_f32
      result = (floats[0] + 0.5_f32).to_i

      if result != expected
        puts "  test failed :("
        break
      end
    end

    puts "  test complete!"
  end

  parser.on("-g", "--gpio", "List the General Purpose Input Output chips available") do
    show_help = false

    puts "\nGPIO Chips\n==================="
    Dir.glob("/dev/gpiochip*").sort!.each do |path|
      puts "* path: #{path}"

      begin
        chip = GPIO::Chip.new(Path[path])
        puts "  #{chip.name} (#{chip.label})"
        puts "  lines: #{chip.num_lines}"
      rescue error
        puts "  error: #{error.message}"
      end
    end
    puts ""
  end

  parser.on("-i PATH", "--inspect=PATH", "inspects the specified GPIO path") do |path|
    show_help = false

    puts "\nGPIO: #{path}\n==================="
    chip = GPIO::Chip.new(Path[path])
    puts "* #{chip.name} (#{chip.label})"
    puts "  path:  #{path}"
    puts "  lines: #{chip.num_lines}"
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
                  if size.type.discrete?
                    rate = size.frame_rate
                    str << "\n    "
                    rate.width.to_s(str)
                    str << "x"
                    rate.height.to_s(str)
                    str << " ("
                    rate.fps.round(1).to_s(str)
                    str << "fps)"
                  else
                    str << "\n    "
                    size.max_width.to_s(str)
                    str << "x"
                    size.max_height.to_s(str)
                    if size.type.stepwise?
                      str << " ("
                      if size.step_width == size.step_height
                        size.step_width.to_s(str)
                        str << "px step)"
                      else
                        size.step_width.to_s(str)
                        str << "w "
                        size.step_height.to_s(str)
                        str << "h step)"
                      end
                    end
                  end

                  str << " ["
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
        puts "\n* #{dev_path} (#{error.message})"
        if backtrace = error.backtrace
          puts backtrace.join("\n")
        end
      end
    end
  end

  parser.on("-h", "--help", "Show this help") do
    show_help = true
  end
end

puts parse if show_help
