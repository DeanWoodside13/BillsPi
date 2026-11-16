#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
# Script Purpose and Overview:
# This script configures Raspberry Pi OS Lite (64-bit, kernel 6.6, Debian 12 Bookworm) for optimal performance 
# on Raspberry Pi 5 hardware by minimizing power consumption and resource usage. It disables unused interfaces 
# and devices, reduces GPU memory allocation, unbinds USB 2.0 ports, and disables unnecessary services such as 
# audio and wireless. These optimizations are designed to streamline the system for headless server use while 
# conserving system resources.
#
# Key Features and Optimizations:
# 1. Disable Unused Interfaces:
#    - Disables HDMI, onboard audio, GPIO, UART, SPI, I2C, WiFi, Bluetooth, PCIe, MIPI DSI, and the camera interface
#      to reduce power consumption and prevent unnecessary kernel module loading.
#
# 2. Reduce GPU Memory Allocation:
#    - Sets the GPU memory allocation to the minimum (16MB) to maximize RAM available for system use.
#
# 3. Blacklist Unused Kernel Modules:
#    - Blacklists kernel modules for GPU, audio, Bluetooth, WiFi, and other unused interfaces to prevent them from 
#      loading and consuming system resources.
#
# 4. Dynamically Disable USB 2.0 Ports:
#    - Detects USB 2.0 buses dynamically and unbinds them at boot to disable the USB 2.0 ports, ensuring only USB 3.0 
#      ports remain active for external devices.
#
# 5. Disable Onboard Ethernet Interface:
#    - Disables the onboard ethernet interface to reduce power consumption. This includes dynamically detecting the 
#      ethernet interface by its driver, checking if it's already down, disabling Wake-on-LAN (WOL), and unbinding 
#      the driver to prevent any interaction with the hardware.
#
# 6. Disable Audio and Wireless Services:
#    - Disables PulseAudio, ALSA, wpa_supplicant, and Bluetooth services if installed, to further minimize boot time 
#      and resource usage for audio and wireless interfaces.
#
# 7. Configure Unused GPIO Pins for Power Savings:
#    - Configures all unused GPIO pins to input mode with pull-up and pull-down resistors disabled to reduce power 
#      consumption and prevent any potential interference from floating pins.
#
# 8. Disable USB OTG and Kernel Logs Over Serial:
#    - Removes any occurrences of 'dtoverlay=dwc2' (which enables USB OTG) and 'console=serial0,115200' 
#      (which sends kernel logs over the serial console), disabling both features.
#
# 9. Automatic Systemd Service Setup:
#    - Creates systemd services to automate the disabling of USB 2.0 ports, onboard ethernet, wireless, audio, 
#      and configuring unused GPIO pins on every boot, ensuring these optimizations persist across reboots without 
#      user intervention.
#
# 10. Lightweight and Resource-Efficient:
#    - The script is tailored for headless server use, minimizing unnecessary hardware usage to reduce power draw, 
#      CPU cycles, and overall system overhead for more efficient performance.
#
# REMOVE THIS, IT MOVED TO 01-system-prerequisites.sh:
# 11. CPU Governor Tweak:
#    - Configures a systemd service to set the CPU governor to `performance`, ensuring maximum clock speed 
#      for improved computation.
#
# Final Configuration:
# - A system reboot may be required for all optimizations to take full effect.
#
# ============================
# Modify /boot/firmware/config.txt
# ============================
echo "Modifying /boot/firmware/config.txt..."

# Keep HDMI available for the provisioning console.
echo "# Reduce GPU memory to the lowest possible amount" | tee -a /boot/firmware/config.txt
echo "gpu_mem=16" | tee -a /boot/firmware/config.txt
echo "" | tee -a /boot/firmware/config.txt

# Disable onboard audio
echo "# Disable onboard + HDMI audio" | tee -a /boot/firmware/config.txt
echo "dtparam=audio=off" | tee -a /boot/firmware/config.txt
# Disable KMS HDMI audio while retaining the HDMI provisioning console.
sed -i -E '/^[[:space:]]*dtoverlay[[:space:]]*=[[:space:]]*vc4-kms-v3d(-pi5)?([[:space:]]|,|$)/ s/([^[:space:]#])([[:space:]]*(#.*)?)$/\1,noaudio\2/' /boot/firmware/config.txt
echo "" | tee -a /boot/firmware/config.txt

# Disable WiFi and Bluetooth
echo "# Disable Wifi and Bluetooth" | tee -a /boot/firmware/config.txt
echo "dtparam=wifi=off" | tee -a /boot/firmware/config.txt
echo "dtoverlay=disable-wifi" | tee -a /boot/firmware/config.txt
echo "dtparam=bluetooth=off" | tee -a /boot/firmware/config.txt
echo "" | tee -a /boot/firmware/config.txt

# ENABLE THIS BLOCK BELOW, LATER IN TESTING

## Disable Gigabit Ethernet
#echo "# Disable Gigabit Ethernet" | tee -a /boot/firmware/config.txt
#echo "dtoverlay=disable-eth" | tee -a /boot/firmware/config.txt
#echo "# Disable Ethernet PHY Clock" | tee -a /boot/firmware/config.txt
#echo "dtoverlay=disable-eth-phy" | tee -a /boot/firmware/config.txt
#echo "" | tee -a /boot/firmware/config.txt

## Disable SD Card interface
#echo "# Disable SD Card interface" | tee -a /boot/firmware/config.txt
#echo "dtoverlay=disable-sd" | tee -a /boot/firmware/config.txt
#echo "" | tee -a /boot/firmware/config.txt

# Disable SPI, I2C
echo "# Disable SPI, and I2C" | tee -a /boot/firmware/config.txt
echo "dtparam=i2c=off" | tee -a /boot/firmware/config.txt
echo "dtparam=spi=off" | tee -a /boot/firmware/config.txt
echo "" | tee -a /boot/firmware/config.txt

# Disable PCIe, LEDs, MIPI DSI, Camera interface
echo "# Disable PCIe, LEDs, MIPI DSI, and Camera interface" | tee -a /boot/firmware/config.txt

# On Pi 4, disabling PCIe takes out the USB-A ports; 
# on Pi 5, the RP1 I/O complex is PCIe-attached and similar breakage can occur.
# Keep PCIe on since your NIC is USB.
# You can disable PCIe if you fully test with 2.5 GBPs in future
# uncomment this line below at that time !
# echo "dtoverlay=disable-pcie" | tee -a /boot/firmware/config.txt
echo "dtparam=act_led_trigger=none" | tee -a /boot/firmware/config.txt
echo "dtparam=act_led_activelow=on" | tee -a /boot/firmware/config.txt
echo "display_auto_detect=0" | tee -a /boot/firmware/config.txt
echo "camera_auto_detect=0" | tee -a /boot/firmware/config.txt
echo "" | tee -a /boot/firmware/config.txt

# Disable Serial Console (UART)
echo "# Disable Serial Console (UART)" | tee -a /boot/firmware/config.txt
echo "dtparam=uart=off" | tee -a /boot/firmware/config.txt
echo "enable_uart=0" | tee -a /boot/firmware/config.txt
echo "" | tee -a /boot/firmware/config.txt

# Disable USB gadget/OTG and silence kernel logs over UART
# - Edits active boot files under /boot/firmware (Bookworm path)
# - In cmdline.txt:
#     * remove 'console=serial0,115200' (no kernel logs on UART)
#     * remove 'console=tty1' (optional: no VT console)
#     * remove any 'modules-load=...dwc2...' token (don't autoload dwc2/gadget)
#     * normalize whitespace on the single line
# - In config.txt:
#     * remove 'dtoverlay=dwc2' (disables USB OTG overlay)
# Reboot required.
#sed -i -E -e 's/\bconsole=serial0,115200\b//g' -e 's/\bconsole=tty1\b//g' \
#  -e 's/\bmodules-load=[^ ]*dwc2[^ ]*//g' -e 's/[[:space:]]+/ /g; s/^ //; s/ $//' \
#  "/boot/firmware/cmdline.txt"
#sed -i -E '/^\s*dtoverlay=dwc2(\b|,|=).*$/d' "/boot/firmware/config.txt"


# Disable USB gadget/OTG and the kernel UART console.
# Edits /boot/firmware (Bookworm path):
#  - cmdline.txt: remove console=serial0,115200; remove console=tty1 (disables VT console);
#    drop any modules-load=...dwc2...; then normalize whitespace.
#  - config.txt: remove dtoverlay=dwc2 (disable OTG overlay).
# Effective on next reboot.
sed -i -E -e 's/(^|[[:space:]])console=serial0,115200([[:space:]]|$)/ /g' \
          -e 's/(^|[[:space:]])modules-load=[^[:space:]]*dwc2[^[:space:]]*([[:space:]]|$)/ /g' \
          -e 's/[[:space:]]+/ /g; s/^ //; s/ $//' \
          "/boot/firmware/cmdline.txt"
sed -i -E '/^[[:space:]]*dtoverlay=dwc2([[:space:]]|,|=).*$/d' "/boot/firmware/config.txt"
# sed -i -E '/^[[:space:]]*dtoverlay[[:space:]]*=[[:space:]]*dwc2([[:space:]]|,|=).*$/d' "/boot/firmware/config.txt"



# HDMI remains enabled so later provisioning phases are visible.

# ============================
# Modify /etc/modprobe.d/raspi-blacklist.conf
# ============================
echo "Modifying /etc/modprobe.d/raspi-blacklist.conf..."

tee /etc/modprobe.d/raspi-blacklist.conf <<'EOF'
# Keep the display modules for the provisioning console.
 
# Hard-block ALSA entirely
blacklist snd

# SoC/onboard audio off
blacklist snd_bcm2835
install  snd_bcm2835 /bin/false
blacklist snd_soc_core

# If you also want to prevent *USB audio* devices from appearing:
blacklist snd_usb_audio
install  snd_usb_audio /bin/false

# Disable Bluetooth modules
blacklist btbcm
blacklist hci_uart
blacklist bluetooth

# Disable WiFi modules
blacklist brcmfmac
blacklist brcmutil

# Disable Camera, I2C, SPI, and UART
blacklist bcm2835_v4l2
blacklist i2c-bcm2835
blacklist spidev
blacklist serial8250
EOF

# ============================
# Create systemd service to disable USB 2.0 ports
# ============================
echo "Creating systemd service to disable USB 2.0 ports..."

# Create the disable-usb.sh script with dynamic detection of USB 2.0 ports
tee /usr/local/bin/disable-usb.sh <<'EOF'
#!/bin/bash
set -euo pipefail
# Disable all USB 2.0 root hubs (480 Mbps) by unbinding their host controllers.
for hub in /sys/bus/usb/devices/usb*; do
  [ -r "$hub/speed" ] || continue
  speed=$(cat "$hub/speed" 2>/dev/null || echo "")
  if [ "$speed" = "480" ]; then
    dev=$(basename "$hub")   # e.g., usb1
    echo "Unbinding $dev (USB2 root hub at 480 Mbps)"
    echo "$dev" > /sys/bus/usb/drivers/usb/unbind
  fi
done
EOF

# Make disable-usb.sh executable
chmod +x /usr/local/bin/disable-usb.sh

# Create the systemd service file
tee /etc/systemd/system/disable-usb.service <<'EOF'
[Unit]
Description=Disable USB 2.0 ports on boot
After=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disable-usb.sh

[Install]
WantedBy=multi-user.target
EOF

########################################################################################################################
# THE BLOCK BELOW IS ENTIRELY COMMENTED OUT; ONLY USE IF YOU DECIDE TO DISABLE BOTH USB 2.0 AND USB 3.0 IN LIEU OF ABOVE
## Create the disable-usb.sh script with dynamic detection of USB 2.0 and USB 3.0 ports
#tee /usr/local/bin/disable-usb.sh <<EOF
##!/bin/bash
## Find and disable all USB 2.0 and USB 3.0 buses dynamically using lsusb -t
## Disable USB 2.0 (480M)
#USB2_BUSES=$(lsusb -t | grep -B 1 "480M" | grep "Bus" | awk '{print $2}')
## Disable USB 3.0 (5000M)
#USB3_BUSES=$(lsusb -t | grep -B 1 "5000M" | grep "Bus" | awk '{print $2}')
## Check and disable USB 2.0 buses
#if [ -n "$USB2_BUSES" ]; then
#   for bus in $USB2_BUSES; do
#       echo "Disabling USB 2.0 bus: $bus"
#       echo "$bus" | tee /sys/bus/usb/drivers/usb/unbind
#   done
#else
#  echo "No USB 2.0 buses found!"
#fi
## Check and disable USB 3.0 buses
#if [ -n "$USB3_BUSES" ]; then
#   for bus in $USB3_BUSES; do
#       echo "Disabling USB 3.0 bus: $bus"
#       echo "$bus" | tee /sys/bus/usb/drivers/usb/unbind
#   done
#else
#   echo "No USB 3.0 buses found!"
#fi
#EOF
########################################################################################################################


# ============================
# Create systemd service to disable unusued GPIO pins for power savings
# ============================
echo "Creating systemd service to disable unused GPIO pins..."

# Create the disable-gpio.sh script
tee /usr/local/bin/disable-gpio.sh <<'EOF'
#!/bin/bash
set -euo pipefail

# Configure unused GPIO pins for power savings
echo "Configuring unused GPIO pins for power savings..."
# List of GPIO pins to disable (Raspberry Pi 5)
GPIO_PINS=(2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27)
# Loop through all GPIO pins and set them to input mode with no pull-up/pull-down resistors
for PIN in "${GPIO_PINS[@]}"; do
    echo "Disabling GPIO $PIN..."
    # Pi 5 GPIOs are controlled by pinctrl; pn disables the pulls.
    pinctrl set "$PIN" ip pn
done
echo "GPIO pins configured for minimal power consumption."
EOF

# Make disable-gpio.sh executable
chmod +x /usr/local/bin/disable-gpio.sh

# Create the systemd service file
tee /etc/systemd/system/disable-gpio.service <<'EOF'
[Unit]
Description=Configure GPIO pins for minimal power consumption on boot

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disable-gpio.sh

[Install]
WantedBy=multi-user.target
EOF



# ============================
# Create a systemd service to disable the ethernet interface on boot
# ============================
echo "Creating systemd service to disable onboard ethernet interface on startup..."

# Create the disable-onboard-eth.sh script
tee /usr/local/bin/disable-onboard-eth.sh <<'EOF'
#!/bin/bash
set -euo pipefail

choose_iface() {
  local preferred=""
  for dev in /sys/class/net/*; do
    local name=$(basename "$dev")
    [ "$name" = "lo" ] && continue
    [[ "$name" != e* ]] && continue          # en*, eth*, end*, enx*
    [ -e "$dev/device/driver" ] || continue  # must have a bound driver

    # Skip USB NICs (keep your 2.5GbE dongle alive)
    local subsys
    subsys=$(basename "$(readlink -f "$dev/device/subsystem")" 2>/dev/null || echo "")
    [ "$subsys" = "usb" ] && continue

    # Prefer explicit "onboard" naming if present
    if udevadm info -q property -p "$dev" 2>/dev/null | grep -q '^ID_NET_NAME_ONBOARD='; then
      echo "$name"; return 0
    fi
    # Common onboard names on Pi
    if [[ "$name" =~ ^(end0|eth0)$ ]]; then
      echo "$name"; return 0
    fi
    [ -z "$preferred" ] && preferred="$name"
  done
  echo "$preferred"
}

IFACE="$(choose_iface)"
if [ -z "$IFACE" ]; then
  echo "No candidate onboard ethernet interface found; skipping."
  exit 0
fi

# Safety: don't kill the active uplink
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '$1 == "default" { for (i=1; i<NF; i++) if ($i == "dev") { print $(i+1); exit } }' || true)
if [ "$DEFAULT_IF" = "$IFACE" ]; then
  echo "Refusing to disable $IFACE (it's the current default-route interface)."
  exit 0
fi

echo "Disabling onboard ethernet interface: $IFACE"

# Bring it down if up
if ip link show "$IFACE" | grep -q "state UP"; then
  ip link set "$IFACE" down || true
fi

# Disable Wake-on-LAN
if command -v ethtool >/dev/null 2>&1; then
  ethtool -s "$IFACE" wol d || true
fi

# Unbind the driver
DEV=$(basename "$(readlink -f "/sys/class/net/$IFACE/device")")
DRV="/sys/class/net/$IFACE/device/driver"
if [ -e "$DRV/unbind" ]; then
  echo "Unbinding driver from $DEV"
  echo "$DEV" > "$DRV/unbind"
fi
EOF

# Make disable-onboard-eth.sh executable
chmod +x /usr/local/bin/disable-onboard-eth.sh


# Create the systemd service file
tee /etc/systemd/system/disable-onboard-eth.service <<'EOF'
[Unit]
Description=Disable onboard Ethernet (keep USB 2.5GbE)
After=systemd-udev-settle.service
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disable-onboard-eth.sh

[Install]
WantedBy=multi-user.target
EOF

# If dhcpcd is in use, tell it to ignore onboard NICs
if [ -f /etc/dhcpcd.conf ]; then
  # Add once, idempotently
  if ! grep -qE '^\s*denyinterfaces\b.*\bend0\b' /etc/dhcpcd.conf 2>/dev/null || \
     ! grep -qE '^\s*denyinterfaces\b.*\beth0\b' /etc/dhcpcd.conf 2>/dev/null; then
    echo 'denyinterfaces end0 eth0' | tee -a /etc/dhcpcd.conf >/dev/null
  fi
  # Soft restart if the service exists
  systemctl try-restart dhcpcd.service 2>/dev/null || true
fi

# If systemd-networkd is installed, add a "do-nothing" network for onboard NICs
install -d -m 0755 /etc/systemd/network

tee /etc/systemd/network/99-ignore-onboard-eth.network <<'EOF'
[Match]
Name=end0
Name=eth0

[Network]
DHCP=no
LinkLocalAddressing=no
LLMNR=no
MulticastDNS=no
IPv6AcceptRA=no
IPv6LinkLocalAddressGeneration=no
EmitLLDP=no

[DHCPv4]
UseDNS=no
UseNTP=no

[DHCPv6]
UseDNS=no
UseNTP=no
EOF

# Reload networkd if present
systemctl try-restart systemd-networkd.service 2>/dev/null || true


# ============================
# Create a systemd service to disable audio services on boot
# ============================
echo "Creating systemd service to disable audio services on startup..."
# Create the disable-audio.sh script

# Pulseaudio is not on Raspberry Pi OS Lite so this is commented out
## Disable PulseAudio service (if installed)
#if systemctl list-unit-files | grep -q pulseaudio.service; then
#    if systemctl is-active --quiet pulseaudio.service; then
#        systemctl stop pulseaudio.service
#        if [ $? -ne 0 ]; then
#            echo "Failed to stop PulseAudio service." >&2
#            exit 1
#        else
#            echo "PulseAudio service stopped successfully."
#        fi
#    else
#        echo "PulseAudio service is already stopped."
#    fi
#    
#    systemctl disable pulseaudio.service
#    if [ $? -ne 0 ]; then
#        echo "Failed to disable PulseAudio service." >&2
#        exit 1
#    else
#        echo "PulseAudio service disabled successfully."
#    fi
#else
#    echo "PulseAudio service not found, skipping."
#fi

tee /usr/local/bin/disable-audio.sh <<'EOF'
#!/bin/bash
set -euo pipefail

# Disable ALSA service (if installed)
if systemctl list-unit-files | grep -E '^alsa-utils\.service[[:space:]]' >/dev/null; then
    if systemctl is-active --quiet alsa-utils.service; then
        systemctl stop alsa-utils.service
        if [ $? -ne 0 ]; then
            echo "Failed to stop ALSA service." >&2
            exit 1
        else
            echo "ALSA service stopped successfully."
        fi
    else
        echo "ALSA service is already stopped."
    fi
    
    systemctl disable alsa-utils.service
    if [ $? -ne 0 ]; then
        echo "Failed to disable ALSA service." >&2
        exit 1
    else
        echo "ALSA service disabled successfully."
    fi
else
    echo "ALSA service not found, skipping."
fi
EOF

# Make the script executable
chmod +x /usr/local/bin/disable-audio.sh

# Create the systemd service file for audio
tee /etc/systemd/system/disable-audio.service <<'EOF'
[Unit]
Description=Disable Audio services (PulseAudio and ALSA)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disable-audio.sh

[Install]
WantedBy=multi-user.target
EOF



# ============================
# Create a systemd service to disable wireless services on boot
# ============================
echo "Creating systemd service to disable wireless services on startup..."
# Create the disable-wireless.sh script
tee /usr/local/bin/disable-wireless.sh <<'EOF'
#!/bin/bash
set -euo pipefail

# Disable wpa_supplicant service (for WiFi)
if systemctl list-unit-files | grep -E '^wpa_supplicant\.service[[:space:]]' >/dev/null; then
    if systemctl is-active --quiet wpa_supplicant.service; then
        systemctl stop wpa_supplicant.service
        if [ $? -ne 0 ]; then
            echo "Failed to stop wpa_supplicant service." >&2
            exit 1
        else
            echo "wpa_supplicant service stopped successfully."
        fi
    else
        echo "wpa_supplicant service is already stopped."
    fi
    
    systemctl disable wpa_supplicant.service
    if [ $? -ne 0 ]; then
        echo "Failed to disable wpa_supplicant service." >&2
        exit 1
    else
        echo "wpa_supplicant service disabled successfully."
    fi
else
    echo "wpa_supplicant service not found, skipping."
fi

# Disable Bluetooth service
if systemctl list-unit-files | grep -E '^bluetooth\.service[[:space:]]' >/dev/null; then
    if systemctl is-active --quiet bluetooth.service; then
        systemctl stop bluetooth.service
        if [ $? -ne 0 ]; then
            echo "Failed to stop Bluetooth service." >&2
            exit 1
        else
            echo "Bluetooth service stopped successfully."
        fi
    else
        echo "Bluetooth service is already stopped."
    fi
    
    systemctl disable bluetooth.service
    if [ $? -ne 0 ]; then
        echo "Failed to disable Bluetooth service." >&2
        exit 1
    else
        echo "Bluetooth service disabled successfully."
    fi
else
    echo "Bluetooth service not found, skipping."
fi
EOF

# Make the script executable
chmod +x /usr/local/bin/disable-wireless.sh

# Create the systemd service file for wireless
tee /etc/systemd/system/disable-wireless.service <<'EOF'
[Unit]
Description=Disable Wireless services (WiFi and Bluetooth)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disable-wireless.sh

[Install]
WantedBy=multi-user.target
EOF


# Governor is set to performance in 01-system-prerequisites.sh now to benefit the install scripts and shave up to 2 minutes
## TWEAK THE CPU GOVERNOR
## Create the systemd service file for setting the CPU governor to 'performance'
#echo "Creating the CPU governor service..."
#
#tee /etc/systemd/system/cpugovernor.service > /dev/null <<EOL
#[Unit]
#Description=Set CPU governor to performance
#
#[Service]
#Type=oneshot
#ExecStart=/usr/bin/cpufreq-set -g performance
#
#[Install]
#WantedBy=multi-user.target
#EOL
## Reload systemd to recognize the new service
#echo "Reloading systemd..."
#systemctl daemon-reload
#echo "Enabling and starting optimization services..."
#systemctl enable --now cpugovernor.service disable-usb.service disable-gpio.service disable-onboard-eth.service disable-audio.service disable-wireless.service
echo "Enabling and starting optimization services..."
systemctl daemon-reload
systemctl enable --now disable-gpio.service disable-audio.service disable-wireless.service
        # The line below -- disable-onboard-eth.service was removed from the enable --now above; in future with 2.5 GBPS ethernet adapter this one can be run, but not now!  lose connection
        # systemctl enable --now disable-usb.service disable-onboard-eth.service 

## Enable the service to run at boot
#echo "Enabling cpugovernor service..."
#systemctl enable cpugovernor.service
## Optionally, start the service immediately
#echo "Starting cpugovernor service..."
#systemctl start cpugovernor.service
#echo "CPU governor has been set to 'performance' and the service is enabled at boot."


## Reload the systemd daemon, enable and start the services
#systemctl daemon-reload
#systemctl enable disable-usb.service
#systemctl enable disable-gpio.service
#systemctl enable disable-onboard-eth.service
#systemctl enable disable-audio.service
#systemctl enable disable-wireless.service
#systemctl start disable-usb.service
#systemctl start disable-gpio.service
#systemctl start disable-onboard-eth.service
#systemctl start disable-audio.service
#systemctl start disable-wireless.service

echo "Optimization complete!"

touch /run/billspi/reboot-required
exit 0
