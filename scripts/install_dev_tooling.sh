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
    libedgetpu-dev \
    libedgetpu1-std \
    libgpiod-dev

# no longer needed in the docker container so seperating here
apt install -y clang-format-9
