# Edge AI Video Processing

A tool for running AI models at the edge. Designed to minimize latency in processing

## Documentation

To test this out quickly, you can do the following:

```shell
git clone https://github.com/spider-gazelle/edge-ai
cd edge-ai
shards build
cp -R ./www ./bin/www
mkdir ./bin/config
```

then lookup the video hardware you have available

```shell
./bin/hw_info -v
```

this will output something like:

```text
Video Hardware
==============

* /dev/video4
  USB2.0 HD UVC WebCam: USB2.0 IR (uvcvideo)
  - GREY
    640x360 (15.0fps) [DISCRETE]

* /dev/video2
  USB2.0 HD UVC WebCam: USB2.0 HD (uvcvideo)
  - MJPG
    1280x720 (30.0fps) [DISCRETE]
    640x480 (30.0fps) [DISCRETE]
    352x288 (30.0fps) [DISCRETE]
    320x240 (30.0fps) [DISCRETE]
    176x144 (30.0fps) [DISCRETE]
    160x120 (30.0fps) [DISCRETE]
  - YUYV
    1280x720 (10.0fps) [DISCRETE]
    640x480 (30.0fps) [DISCRETE]
    352x288 (30.0fps) [DISCRETE]
    320x240 (30.0fps) [DISCRETE]
    176x144 (30.0fps) [DISCRETE]
    160x120 (30.0fps) [DISCRETE]
```

From this list you probably want to use the

* /dev/video2
* YUYV @ 640x480 (30.0fps)

Then create a config file (this can also be done via the API)
`vim ./bin/config/config.yml`

```yml
---
pipelines:
  3e8bca09-6b54-41aa-96eb-691a964adc50:
    name: web camera
    async: false
    min_score: 0.4
    track_objects: true
    input:
      type: video_device

      # update these as required
      path: /dev/video2
      width: 640
      height: 480
      format: YUYV

      # this multicast stream is used for confidence monitoring
      multicast_ip: 224.0.0.1
      multicast_port: 5000
    output:
    - type: "face_detection"

      # this is a back of phone NN model
      # so expects faces to be a little further away from the camera
      model_uri: "https://raw.githubusercontent.com/patlevin/face-detection-tflite/main/fdlite/data/face_detection_back.tflite"
      scaling_mode: "cover"
      strides: [16, 32, 32, 32]
      gpu_delegate: false
      # tpu_delegate: /sys/bus/usb/devices/4-3
      warnings: []
      pipeline: [
        {
          "type": "gender_estimation",
          "model_uri": "https://os.place.tech/neural_nets/gender/model_lite_gender_q.tflite",
          "scaling_mode": "cover"
        }
      ]
    id: 3e8bca09-6b54-41aa-96eb-691a964adc50
    updated: 2023-12-06 12:40:19.945720369+11:00

```

then you can launch the processes: `cd bin`

* `./processor` - this process performs the detections
* `./interface` - this process is the API and monitoring

For confidence monitoring the configuration above browse to:
[http://127.0.0.1:3000/monitor.html?id=3e8bca09-6b54-41aa-96eb-691a964adc50](http://127.0.0.1:3000/monitor.html?id=3e8bca09-6b54-41aa-96eb-691a964adc50)

then you'll see output like:

![steve](https://github.com/spider-gazelle/edge-ai/assets/368013/6c98f54e-017a-45b7-84bd-2c28c25b0b1e)


## Compiling

`shards build`

### Deploying

Once compiled you are left with a binary `./edge_ai`

* for help `./edge_ai --help`
* viewing routes `./edge_ai --routes`
* run on a different port or host `./edge_ai -b 0.0.0.0 -p 80`
