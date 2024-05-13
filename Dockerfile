FROM 84codes/crystal:latest-debian-12 as build
WORKDIR /app

# Create a non-privileged user, defaults are appuser:10001
ARG IMAGE_UID="10001"
ENV UID=$IMAGE_UID
ENV USER=appuser

# See https://stackoverflow.com/a/55757473/12429735
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/nonexistent" \
    --shell "/sbin/nologin" \
    --no-create-home \
    --uid "${UID}" \
    "${USER}"

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
    ffmpeg \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswscale-dev \
    ca-certificates \
    opencl-headers \
    libopencv-core-dev \
    libgpiod-dev

# Compile Tensorflow lite (the second build in case of error)
RUN git clone --depth 1 --branch "v2.16.1" https://github.com/tensorflow/tensorflow
RUN mkdir tflite_build
WORKDIR /app/tflite_build
RUN cmake ../tensorflow/tensorflow/lite/c -DTFLITE_ENABLE_GPU=ON
RUN cmake --build . -j4 || true
RUN echo "---------- WE ARE BUILDING AGAIN!! ----------"
RUN cmake --build . -j1

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
RUN cp ./out/direct/k8/libedgetpu.so.1.0 /usr/local/lib/libedgetpu.so
RUN cp ./out/direct/k8/libedgetpu.so.1.0 /usr/local/lib/libedgetpu.so.1
RUN ldconfig

# Add src
WORKDIR /app

# Install shards for caching
COPY shard.yml shard.yml
COPY shard.override.yml shard.override.yml
COPY shard.lock shard.lock

RUN shards install --production --ignore-crystal-version --skip-postinstall --skip-executables

# Copy required libs for linking into place
RUN mkdir -p ./lib/tensorflow_lite/ext
RUN mkdir -p ./bin
RUN cp ./libedgetpu/out/direct/k8/libedgetpu.so.1.0 ./bin/libedgetpu.so
RUN cp ./tflite_build/libtensorflowlite_c.so ./lib/tensorflow_lite/ext/
RUN cp ./tflite_build/libtensorflowlite_c.so ./bin/

# Build application
COPY ./src /app/src
RUN shards build --production --error-trace -Dpreview_mt -O1

# Extract binary dependencies (uncomment if not compiling a static build)
RUN for binary in "/usr/bin/ffmpeg" /app/bin/*; do \
        ldd "$binary" | \
        tr -s '[:blank:]' '\n' | \
        grep '^/' | \
        xargs -I % sh -c 'mkdir -p $(dirname deps%); cp % deps%;'; \
    done

# put this in a more convienient location
RUN cp /app/bin/libtensorflowlite_c.so /app/deps/usr/local/lib/

# Generate OpenAPI docs while we still have source code access
RUN ./bin/interface --docs --file=openapi.yml
RUN mkdir ./model_storage
RUN mkdir ./detections
RUN mkdir ./config
RUN mkdir ./clips

# copy the www folder after the build
COPY ./www /app/www

###############################################################################

# Build a minimal docker image
FROM scratch
WORKDIR /
ENV PATH=$PATH:/

# Copy the user information over
COPY --from=build etc/passwd /etc/passwd
COPY --from=build /etc/group /etc/group

# These are required for communicating with external services
# COPY --from=build /etc/hosts /etc/hosts
# doesn't seem to exist.. I could create one?

# These provide certificate chain validation where communicating with external services over TLS
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# This is required for Timezone support
COPY --from=build /usr/share/zoneinfo/ /usr/share/zoneinfo/

# This is your application
COPY --from=build /app/deps /
COPY --from=build /app/bin /
COPY --from=build /app/deps/usr/local/lib/* /lib/

COPY --from=build /usr/bin/ffmpeg /ffmpeg

# configure folders
COPY --from=build /app/model_storage /model_storage
COPY --from=build /app/detections /detections
COPY --from=build /app/config /config
COPY --from=build /app/clips /clips
COPY --from=build /app/www /www

# Copy the API docs into the container
COPY --from=build /app/openapi.yml /openapi.yml

# Use an unprivileged user.
USER appuser:appuser

# Run the app binding on port 3000
EXPOSE 3000
VOLUME ["/clips/", "/model_storage/", "/detections/"]
ENTRYPOINT ["/interface"]
CMD ["/interface", "-b", "0.0.0.0", "-p", "3000"]
