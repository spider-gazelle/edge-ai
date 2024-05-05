require "gpio"
GPIO.default_consumer = "edge-ai"

class EdgeAI::Motion
  def initialize(chip : String, line : Int32)
    @chip = GPIO::Chip.new chip
    @line = @chip.line(line)
    @detected = false

    spawn { monitor_input_changes }
  end

  @line : GPIO::Line

  getter detected : Bool

  def on_motion(&@on_motion : ->)
  end

  def on_idle(&@on_idle : ->)
  end

  def shutdown
    @line.release
  end

  protected def monitor_input_changes
    @line.on_input_change do |input_is|
      begin
        case input_is
        in .rising?
          @detected = true
          @on_motion.try &.call
        in .falling?
          @detected = false
          @on_idle.try &.call
        end
      rescue error
        Log.warn(exception: error) { "error notifying motion state change" }
      end
    end
  end
end
