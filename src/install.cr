#!/usr/bin/env crystal

require "colorize"
require "file"

# Check if the ramdisk is configured to be mounted at startup
def ramdisk_configured?
  fstab_content = File.read("/etc/fstab")
  fstab_content.includes?("/mnt/ramdisk")
end

# Ensure ramdisk is configured to mount at startup
def ensure_ramdisk_config
  if ramdisk_configured?
    puts "\n ✓ Ramdisk configured to mount at startup.".colorize(:green)
  else
    puts "\n → Configuring ramdisk to mount at startup...".colorize(:blue)
    `mkdir -p /mnt/ramdisk`
    File.open("/etc/fstab", "a") do |file|
      file.puts "tmpfs       /mnt/ramdisk   tmpfs   size=512M   0  0"
    end
    `mount -t tmpfs -o size=512M tmpfs /mnt/ramdisk`
    if $?.success?
      puts " ✓ Ramdisk configured.".colorize(:green)
    else
      puts " ✗ Ramdisk may not be configured.".colorize(:red)
    end
  end
end

LOOPBACK_CONFIG = "/etc/modprobe.d/v4l2loopback.conf"
LOOPBACK_MODULE = "/etc/modules-load.d/v4l2loopback.conf"

# Check if loopback device is configured to run at startup
def loopback_configured?
  return false unless File.exists? LOOPBACK_CONFIG
  modprobe_content = File.read(LOOPBACK_CONFIG)
  modprobe_content.includes?("options v4l2loopback")
end

# Ensure loopback device is configured to run at startup with 2 devices
def ensure_loopback_config
  if loopback_configured?
    puts "\n ✓ v4l2loopback configured to load at startup.".colorize(:green)
  else
    puts "\n → Configuring v4l2loopback to load at startup...".colorize(:blue)
    File.open(LOOPBACK_CONFIG, "w") do |file|
      file.puts "options v4l2loopback devices=2"
    end
    # Ensuring module is loaded at startup
    File.open(LOOPBACK_MODULE, "w") do |file|
      file.puts "v4l2loopback"
    end
    `modprobe v4l2loopback devices=2`
    if $?.success?
      puts " ✓ v4l2loopback configured.".colorize(:green)
    else
      puts " ✗ v4l2loopback may not be configured.".colorize(:red)
    end
  end
end

ensure_ramdisk_config
ensure_loopback_config
