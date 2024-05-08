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
    libgpiod-dev

# Install shards for caching
COPY shard.yml shard.yml
COPY shard.override.yml shard.override.yml
COPY shard.lock shard.lock

RUN shards install --production --ignore-crystal-version --skip-postinstall --skip-executables

# Compile Tensorflow lite
RUN git clone --depth 1 --branch "v2.16.1" https://github.com/tensorflow/tensorflow
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

# Compile flatbuffers
WORKDIR /app
RUN git clone --branch v23.5.26 --depth 1 https://github.com/google/flatbuffers
WORKDIR /app/flatbuffers
RUN cmake -G "Unix Makefiles" \
          -DCMAKE_BUILD_TYPE=Release \
          -DFLATBUFFERS_BUILD_SHAREDLIB:BOOL=ON
RUN make && make install

# Compile libedgetpu
WORKDIR /app
RUN git clone https://github.com/google-coral/libedgetpu
WORKDIR /app/libedgetpu

# TODO:: remove once https://github.com/google-coral/libedgetpu/pull/66 is merged
RUN git remote add upstream https://github.com/NobuoTsukamoto/libedgetpu
RUN git fetch upstream
RUN git config --global user.email "example@example.com"
RUN git config --global user.name "Your Name"
RUN git cherry-pick dff851aa3124afce5f7d149c843d82b14c05c075

RUN apt install -y libabsl-dev libusb-1.0-0-dev
ENV LDFLAGS="-L/usr/local/lib"
ENV TFROOT="../tensorflow"
RUN make -f makefile_build/Makefile -j$(nproc) libedgetpu
RUN cp ./out/direct/k8/libedgetpu.so.1.0 ../bin/libedgetpu.so
RUN cp ./out/direct/k8/libedgetpu.so.1.0 /usr/local/lib/libedgetpu.so
RUN cp ./out/direct/k8/libedgetpu.so.1.0 /usr/local/lib/libedgetpu.so.1
RUN ldconfig

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
    wget \
    curl \
    rsync \
    gnupg \
    apt-transport-https \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# copy the application over
COPY --from=build /app/bin /
COPY --from=build /app/deps /tmp_deps
RUN rsync -av /tmp_deps/ /
RUN rm -rf ./tmp_deps
RUN mv /app/bin/libtensorflowlite_c.so /usr/local/lib/
ENV LDFLAGS="-L/usr/local/lib"
RUN ldconfig
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
