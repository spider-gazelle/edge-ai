require "./spec_helper"

module EdgeAI
  describe EdgeAI::Configuration do
    client = AC::SpecHelper.client

    it "should list devices available" do
      result = client.get("/api/edge/ai/devices")
      puts JSON.parse(result.body).to_pretty_json
      result.success?.should be_true
    end
  end
end
