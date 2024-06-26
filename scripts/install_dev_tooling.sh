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
    clinfo \
    ocl-icd-opencl-dev \
    libopencv-core-dev \
    libgpiod-dev \
    libabsl-dev \
    libusb-1.0-0-dev \
    plocate \
    docker-buildx-plugin \
    ffmpeg \
    libgpiod-dev \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswscale-dev \
    jq

docker buildx install

# add multi-arch image build support
docker run --privileged --rm tonistiigi/binfmt --install all

# Define the path to the Docker daemon configuration file
DAEMON_CONFIG="/etc/docker/daemon.json"

# Check if the Docker daemon configuration file already exists
if [ -f "$DAEMON_CONFIG" ]; then
    # The file exists, check if 'features' is already set
    if grep -q '"features":' "$DAEMON_CONFIG"; then
        # 'features' exists, modify it to ensure 'buildkit' is enabled
        sudo jq '.features.buildkit = true' "$DAEMON_CONFIG" > temp.json && sudo mv temp.json "$DAEMON_CONFIG"
    else
        # 'features' does not exist, add it with 'buildkit' enabled
        sudo jq '.features = {"buildkit": true}' "$DAEMON_CONFIG" > temp.json && sudo mv temp.json "$DAEMON_CONFIG"
    fi
else
    # The file does not exist, create it with 'buildkit' enabled
    echo '{"features":{"buildkit":true}}' | sudo tee "$DAEMON_CONFIG" > /dev/null
fi

# Restart Docker to apply changes
sudo systemctl restart docker

echo "Docker daemon configuration updated and Docker restarted."

docker run --privileged --rm tonistiigi/binfmt --install all
docker buildx create --name mybuilder --driver docker-container --use
docker buildx inspect --bootstrap
docker buildx use mybuilder

echo "========================"
echo "===Installing Crystal==="
echo "========================"
curl -fsSL https://packagecloud.io/84codes/crystal/gpgkey | gpg --dearmor | tee /etc/apt/trusted.gpg.d/84codes_crystal.gpg > /dev/null
. /etc/os-release
echo "deb https://packagecloud.io/84codes/crystal/$ID $VERSION_CODENAME main" | tee /etc/apt/sources.list.d/84codes_crystal.list
apt update
apt install -y crystal
