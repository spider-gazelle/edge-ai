#!/bin/sh

# Assumes you have git installed as you cloned this repository
# you may have to `sudo apt install raspberrypi-kernel-headers` on a pi

# Check if the script is running as root
if [ "$(id -u)" != "0" ]; then
    echo "Must run as root. Restarting with sudo..."
    # Re-execute the script with sudo
    sudo "$0" "$@"
    exit $?
fi

echo "========================"
echo "===Installing Tooling==="
echo "========================"
apt update
apt install -y wget curl coreutils dnsutils ca-certificates lsb-release iproute2 gnupg apt-transport-https

# Obtain the OS distributor name
DISTRO=$(lsb_release -i | cut -d: -f2 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

echo "======================="
echo "===Installing Docker==="
echo "======================="
# Add Docker's official GPG key:
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$DISTRO/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$DISTRO \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update

apt install -y python3-distutils-extra docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Determine the architecture
ARCH=$(uname -m)

# add docker-compose command for backwards compat
curl -SL https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-$ARCH -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
chmod +x /usr/bin/docker-compose

groupadd docker

# Obtain the current username who invoked sudo
CURRENT_USER=${SUDO_USER:-$(whoami)}

# Add the current user to the docker group
usermod -aG docker "$CURRENT_USER"

echo "User $CURRENT_USER added to docker group."

# add crystal lang
echo "========================"
echo "===Installing Crystal==="
echo "========================"
curl -fsSL https://packagecloud.io/84codes/crystal/gpgkey | gpg --dearmor | tee /etc/apt/trusted.gpg.d/84codes_crystal.gpg > /dev/null
. /etc/os-release
echo "deb https://packagecloud.io/84codes/crystal/$ID $VERSION_CODENAME main" | tee /etc/apt/sources.list.d/84codes_crystal.list
apt update
apt install -y crystal

# add edge tpu delegate support
echo "==========================="
echo "===Installing TPU Driver==="
echo "==========================="
wget -q -O - https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor > /etc/apt/trusted.gpg.d/coral-edgetpu.gpg
echo "deb [signed-by=/etc/apt/trusted.gpg.d/coral-edgetpu.gpg] https://packages.cloud.google.com/apt coral-edgetpu-stable main" | tee /etc/apt/sources.list.d/coral-edgetpu.list
apt update
apt install -y usbutils libedgetpu-dev libedgetpu1-std
systemctl restart udev

# install video for linux 2
echo "================================"
echo "===Installing Video for Linux==="
echo "================================"
apt install -y v4l-utils v4l2loopback-dkms

# Create the gpio-users group
groupadd video-users

# Add the current user to the gpio-users group
usermod -aG video-users "$CURRENT_USER"

# Write the udev rule
echo 'KERNEL=="video*", OWNER="10001", GROUP="video-users", MODE="0660"' > /etc/udev/rules.d/99-videodevice-owner.rules

echo "User $CURRENT_USER video udev rule set."

# install GPIO for controlling relays and reading motion detectors
echo "==================================="
echo "===Installing General Purpose IO==="
echo "==================================="
apt install -y gpiod libgpiod-dev

# Create the gpio-users group
groupadd gpio-users

# Add the current user to the gpio-users group
usermod -aG gpio-users "$CURRENT_USER"

# Write the udev rule
echo 'KERNEL=="gpiochip*", OWNER="10001", GROUP="gpio-users", MODE="0660"' > /etc/udev/rules.d/99-gpiochip.rules

# Reload the udev rules
udevadm control --reload-rules
udevadm trigger

echo "User $CURRENT_USER added to gpio-users and udev rule set."

# Ensure the OS is configured
echo "===================="
echo "===Configuring OS==="
echo "===================="

# increase the swap memory
# Path to the swap configuration file
SWAP_FILE="/etc/dphys-swapfile"

# Desired configurations
CONF_SWAPSIZE="CONF_SWAPSIZE=4096"
CONF_MAXSWAP="CONF_MAXSWAP=4096"

# Function to update configuration if not set
update_config() {
  local config_name=$1
  local config_value=$2
  local config_line="$config_name=$config_value"

  # Check if the configuration already exists
  if grep -q "^$config_name=" "$SWAP_FILE"; then
    # Configuration exists, update it if necessary
    if ! grep -q "^$config_line$" "$SWAP_FILE"; then
      echo "Updating $config_name to $config_value"
      sed -i "s/^$config_name=.*/$config_line/" "$SWAP_FILE"
    else
      echo "$config_name is already set to $config_value"
    fi
  else
    # Configuration does not exist, append it
    echo "Adding $config_line to $SWAP_FILE"
    echo "$config_line" >> "$SWAP_FILE"
  fi
}

# Update swap size
update_config "CONF_SWAPSIZE" "4096"

# Update max swap
update_config "CONF_MAXSWAP" "4096"

# Restart swap service to apply changes
echo "Restarting swap service to apply changes..."
dphys-swapfile swapoff
dphys-swapfile setup
dphys-swapfile swapon

# enable multicast on loopback device

# Bring up the loopback interface
ip link set lo up

# Add the multicast route
ip route add 224.0.0.0/4 dev lo

# run the crystal lang install helper
sudo -u "$CURRENT_USER" shards build --production --ignore-crystal-version --skip-postinstall --skip-executables install
./bin/install
