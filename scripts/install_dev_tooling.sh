#!/bin/sh

# Check if the script is running as root
if [ "$(id -u)" != "0" ]; then
    echo "Must run as root. Restarting with sudo..."
    sudo "$0" "$@"
    exit $?
fi

echo "=================================="
echo "===Installing Development Tools==="
echo "=================================="
apt update && apt install -y \
    build-essential \
    cmake \
    linux-headers-generic \
    git \
    wget \
    curl \
    python3 \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswscale-dev \
    ca-certificates \
    opencl-headers \
    libopencv-core-dev \
    libgpiod-dev \
    libabsl-dev \
    libusb-1.0-0-dev \
    plocate \
    docker-buildx-plugin

docker buildx install

# add multi-arch image build support
docker run --privileged --rm tonistiigi/binfmt --install all
