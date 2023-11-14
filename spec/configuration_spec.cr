require "./spec_helper"

module EdgeAI
  describe EdgeAI::Configuration do
    client = AC::SpecHelper.client

    change_count = 0
    monitor = EdgeAI::ConfigChange.instance
    monitor.on_change do |_config_yaml|
      change_count += 1
    end

    Spec.before_suite do
      File.write EdgeAI::PIPELINE_CONFIG, %({"pipelines": {}})
      monitor.watch
      sleep 0.1
    end

    it "should list config" do
      result = client.get("/api/edge/ai/config")
      result.body.should eq %([])
      change_count.should eq 0
    end

    it "should add new config" do
      result = client.post("/api/edge/ai/config", body: INDEX0_CONFIG)
      cleanup(result.body).should eq INDEX0_CONFIG

      second_result = client.get("/api/edge/ai/config")
      second_result.body.should eq %([#{result.body}])

      sleep 0.1
      change_count.should eq 2
    end

    it "should fetch the new config" do
      result = client.get("/api/edge/ai/config")
      id = JSON.parse(result.body)[0]["id"].as_s

      result = client.get("/api/edge/ai/config/#{id}")
      cleanup(result.body).should eq INDEX0_CONFIG
    end

    it "should replace the configuration with new configuration" do
      result = client.get("/api/edge/ai/config")
      id = JSON.parse(result.body)[0]["id"].as_s

      result = client.put("/api/edge/ai/config/#{id}", body: INDEX0_CONFIG)
      cleanup(result.body).should eq INDEX0_CONFIG

      second_result = client.get("/api/edge/ai/config")
      second_result.body.should eq %([#{result.body}])

      sleep 0.1
      change_count.should eq 3
    end

    it "should delete the config" do
      result = client.get("/api/edge/ai/config")
      id = JSON.parse(result.body)[0]["id"].as_s

      result = client.delete("/api/edge/ai/config/#{id}")
      result.success?.should be_true

      result = client.get("/api/edge/ai/config")
      result.body.should eq %([])

      sleep 0.1
      change_count.should eq 4
    end
  end
end
