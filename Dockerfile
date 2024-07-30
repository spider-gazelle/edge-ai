FROM stakach/tensorflowlite:latest as tflite
FROM 84codes/crystal:latest-ubuntu-24.04 as build
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

# Add dependencies commonly required for building crystal applications
# hadolint ignore=DL3018
RUN apt-get update && apt-get install -y \
    gnupg \
    curl \
    apt-transport-https \
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
    libgpiod-dev \
    libabsl-dev \
    libusb-1.0-0-dev && \
    apt-get clean

WORKDIR /app

# Install shards for caching
COPY shard.yml shard.yml
COPY shard.override.yml shard.override.yml
COPY shard.lock shard.lock

RUN shards install --production --ignore-crystal-version --skip-postinstall --skip-executables

# Copy required libs for linking into place
ENV LDFLAGS="-L/usr/local/lib"
COPY --from=tflite /usr/local/lib/libedgetpu.so /usr/local/lib/libedgetpu.so
COPY --from=tflite /usr/local/lib/libtensorflowlite_c.so /usr/local/lib/libtensorflowlite_c.so
COPY --from=tflite /usr/local/lib/libtensorflowlite_gpu_delegate.so /usr/local/lib/libtensorflowlite_gpu_delegate.so
RUN ldconfig

RUN mkdir -p ./lib/tensorflow_lite/ext
RUN mkdir -p ./bin
RUN cp /usr/local/lib/libtensorflowlite_c.so /app/lib/tensorflow_lite/ext/libtensorflowlite_c.so
RUN cp /usr/local/lib/libtensorflowlite_c.so /app/bin/libtensorflowlite_c.so

RUN cp /usr/local/lib/libtensorflowlite_gpu_delegate.so /app/lib/tensorflow_lite/ext/libtensorflowlite_gpu_delegate.so
RUN cp /usr/local/lib/libtensorflowlite_gpu_delegate.so /app/bin/libtensorflowlite_gpu_delegate.so

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
COPY --from=build /app/bin/libtensorflowlite_c.so /lib/libtensorflowlite_c.so
COPY --from=build /app/bin/libtensorflowlite_gpu_delegate.so /lib/libtensorflowlite_gpu_delegate.so
COPY --from=tflite /usr/local/lib/libOpenCL.so /lib/libOpenCL.so

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
