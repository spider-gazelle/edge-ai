require "spec"

# Helper methods for testing controllers (curl, with_server, context)
require "action-controller/spec_helper"

# Your application config
# If you have a testing environment, replace this with a test config file
require "../src/config"

::Log.setup("*", :trace)

Spec.before_suite do
  ::Log.setup("*", :trace)
end

Spec.after_suite do
  File.write EdgeAI::PIPELINE_CONFIG, %({"pipelines": {}})
end

INDEX0_CONFIG = JSON.parse(%({
  "name": "image",
  "async": false,
  "track_objects": false,
  "min_score": 0.2,
  "input": {
    "type": "image"
  },
  "output": [{
    "type": "object_detection",
    "model_uri": "https://storage.googleapis.com/tfhub-lite-models/tensorflow/lite-model/efficientdet/lite2/detection/metadata/1.tflite",
    "scaling_mode": "cover", "gpu_delegate":false,"warnings":[],"pipeline":[]
  },{
    "type": "face_detection",
    "model_uri": "https://raw.githubusercontent.com/patlevin/face-detection-tflite/main/fdlite/data/face_detection_back.tflite",
    "scaling_mode": "cover",
    "gpu_delegate":false,
    "strides": [16, 32, 32, 32],
    "warnings":[],
    "pipeline":[]
  },{
    "type": "pose_detection",
    "model_uri": "https://storage.googleapis.com/tfhub-lite-models/google/lite-model/movenet/singlepose/lightning/tflite/int8/4.tflite",
    "scaling_mode": "cover", "gpu_delegate":false,"warnings":[],"pipeline":[]
  }]
})).to_json

module EdgeAI
  def self.cleanup(json) : String
    resp = JSON.parse(json).as_h
    resp.delete("updated")
    resp.delete("id")
    resp.to_json
  end
end
