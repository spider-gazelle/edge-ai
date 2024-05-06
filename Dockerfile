FROM 84codes/crystal:latest-debian-12 as build
WORKDIR /app

# Update system and install required packages
RUN apt-get update && apt-get install -y \
    gnupg \
    wget \
    curl \
    apt-transport-https \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Add Google Cloud public key
RUN wget -q -O - https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor > /etc/apt/trusted.gpg.d/coral-edgetpu.gpg

# Add Coral packages repository
RUN echo "deb [signed-by=/etc/apt/trusted.gpg.d/coral-edgetpu.gpg] https://packages.cloud.google.com/apt coral-edgetpu-stable main" | tee /etc/apt/sources.list.d/coral-edgetpu.list

# Add dependencies commonly required for building crystal applications
# hadolint ignore=DL3018
RUN apt update && apt install -y \
    build-essential \
    cmake \
    linux-headers-generic \
    git \
    wget \
    python3 \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswscale-dev \
    ca-certificates \
    opencl-headers \
    libopencv-core-dev \
    libedgetpu-dev \
    libedgetpu1-std \
    libgpiod-dev

# Install shards for caching
COPY shard.yml shard.yml
COPY shard.override.yml shard.override.yml
COPY shard.lock shard.lock

RUN shards install --production --ignore-crystal-version --skip-postinstall --skip-executables

# Compile Tensorflow lite and put it in place
RUN git clone --depth 1 --branch "v2.8.4" https://github.com/tensorflow/tensorflow
RUN mkdir tflite_build
WORKDIR /app/tflite_build
RUN cmake ../tensorflow/tensorflow/lite/c -DTFLITE_ENABLE_GPU=ON
RUN cmake --build . -j4 || true
RUN echo "---------- WE ARE BUILDING AGAIN!! ----------"
RUN cmake --build . -j1
RUN mkdir -p ../lib/tensorflow_lite/ext
RUN mkdir -p ../bin
RUN cp ./libtensorflowlite_c.so ../lib/tensorflow_lite/ext/
RUN cp ./libtensorflowlite_c.so ../bin/

# Add src
WORKDIR /app
COPY ./src /app/src

# Build application
RUN shards build --production --error-trace -Dpreview_mt -O1

# Extract binary dependencies (uncomment if not compiling a static build)
RUN for binary in /app/bin/*; do \
        ldd "$binary" | \
        tr -s '[:blank:]' '\n' | \
        grep '^/' | \
        xargs -I % sh -c 'mkdir -p $(dirname deps%); cp % deps%;'; \
    done

# Generate OpenAPI docs while we still have source code access
RUN ./bin/interface --docs --file=openapi.yml
RUN update-ca-certificates
RUN mkdir ./model_storage
RUN mkdir ./clips
RUN mkdir ./config

###############################################################################

# Build a minimal docker image
FROM debian:stable-slim
WORKDIR /
ENV PATH=$PATH:/

# Update system and install required packages
RUN apt-get update && apt-get install -y \
    gnupg \
    wget \
    curl \
    apt-transport-https \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Add Google Cloud public key
RUN wget -q -O - https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor > /etc/apt/trusted.gpg.d/coral-edgetpu.gpg

# Add Coral packages repository
RUN echo "deb [signed-by=/etc/apt/trusted.gpg.d/coral-edgetpu.gpg] https://packages.cloud.google.com/apt coral-edgetpu-stable main" | tee /etc/apt/sources.list.d/coral-edgetpu.list

# Install Edge TPU runtime
RUN apt-get update \
    && apt-get install -y libedgetpu1-std \
    && rm -rf /var/lib/apt/lists/*

# copy the application over
COPY --from=build /app/bin /
# COPY --from=build /app/deps /
COPY --from=build /app/model_storage /model_storage
COPY --from=build /app/config /config
COPY --from=build /app/clips /clips
COPY ./www /www

# Copy the docs into the container, you can serve this file in your app
COPY --from=build /app/openapi.yml /openapi.yml

# Run the app binding on port 3000
EXPOSE 3000
VOLUME ["/clips/", "/model_storage/"]
ENTRYPOINT ["/interface"]
CMD ["/interface", "-b", "0.0.0.0", "-p", "3000"]
