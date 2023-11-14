require "./spec_helper"

module EdgeAI
  describe EdgeAI::Configuration do
    client = AC::SpecHelper.client

    Spec.before_suite do
      File.write EdgeAI::PIPELINE_CONFIG, %({"pipelines": {}})
    end

    it "should be able to pass detections to the websocket" do
      Log.trace { "STARTING WS CHECKS" }

      result = client.post("/api/edge/ai/config", body: INDEX0_CONFIG)
      id = JSON.parse(result.body)["id"].as_s
      signal = EdgeAI::DetectionSignal.new(id)
      sleep 0.1
      DetectionOutputs.instance.config_changed
      sleep 0.1

      websocket = client.establish_ws("/api/edge/ai/monitor/detections/#{id}")
      payload = %({"testing": "hello"})

      ws_data = nil
      websocket.on_message do |message|
        ws_data = message
        websocket.close
      end

      spawn do
        signal.send payload
      end

      websocket.run
      ws_data.should eq payload
    end
  end
end
