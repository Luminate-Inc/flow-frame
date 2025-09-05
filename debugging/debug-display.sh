#!/bin/bash

# Debug Art Frame Display Issues on Raspberry Pi
# This script helps diagnose why the display isn't showing anything

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_status "Diagnosing Art Frame display issues on Raspberry Pi..."
echo

# 1. Check what SDL driver the service is actually using
print_status "1. Checking current service configuration and logs..."
echo "Service status:"
sudo systemctl status flow-frame --no-pager -l | grep -E "(Active|Main PID|flow-frame)"

echo
echo "Recent service logs (looking for SDL driver info):"
sudo journalctl -u flow-frame -n 20 --no-pager | grep -E "(SDL|display|video|driver|resolution|window)" || echo "No SDL/display logs found"

echo
echo "Last 10 service log lines:"
sudo journalctl -u flow-frame -n 10 --no-pager

# 2. Check graphics hardware
print_status "2. Checking graphics hardware and drivers..."

echo "KMS/DRM devices:"
if ls /dev/dri/* 2>/dev/null; then
    ls -la /dev/dri/
    print_success "KMS/DRM devices found"
else
    print_warning "No KMS/DRM devices found"
fi

echo
echo "Framebuffer devices:"
if ls /dev/fb* 2>/dev/null; then
    ls -la /dev/fb*
    print_success "Framebuffer devices found"
else
    print_warning "No framebuffer devices found"
fi

echo
echo "Graphics modules loaded:"
lsmod | grep -E "(drm|vc4|fb)" || echo "No graphics modules found"

# 3. Check display/HDMI status
print_status "3. Checking display/HDMI configuration..."

if command -v vcgencmd >/dev/null 2>&1; then
    echo "HDMI status:"
    vcgencmd display_power || echo "Cannot get display power status"
    
    echo "GPU memory:"
    vcgencmd get_mem gpu || echo "Cannot get GPU memory"
    
    echo "Display detection:"
    for i in 0 1; do
        echo "  HDMI $i: $(vcgencmd get_display_power $i 2>/dev/null || echo 'unknown')"
    done
else
    print_warning "vcgencmd not available - cannot check HDMI status"
fi

# 4. Check boot configuration
print_status "4. Checking boot configuration..."

if [ -f "/boot/config.txt" ]; then
    echo "Graphics settings in /boot/config.txt:"
    grep -E "(gpu_mem|dtoverlay|hdmi|framebuffer)" /boot/config.txt || echo "No graphics settings found"
else
    print_warning "/boot/config.txt not found"
fi

# 5. Test different SDL drivers manually
print_status "5. Testing SDL drivers manually..."

if [ -f "./flow-frame" ]; then
    echo "Testing different SDL drivers (each test runs for 5 seconds):"
    
    # Test KMS/DRM
    print_status "Testing KMS/DRM driver..."
    timeout 5 sudo SDL_VIDEODRIVER=kmsdrm DISPLAY=:0 ./flow-frame 2>&1 | head -5 || echo "KMS/DRM test failed or timed out"
    
    # Test framebuffer
    print_status "Testing framebuffer driver..."
    timeout 5 sudo SDL_VIDEODRIVER=fbcon DISPLAY=:0 ./flow-frame 2>&1 | head -5 || echo "Framebuffer test failed or timed out"
    
    # Test software rendering
    print_status "Testing software rendering..."
    timeout 5 sudo SDL_VIDEODRIVER=software DISPLAY=:0 ./flow-frame 2>&1 | head -5 || echo "Software rendering test failed or timed out"
    
else
    print_error "flow-frame executable not found in current directory"
fi

# 6. Check for common Pi display issues
print_status "6. Checking for common Raspberry Pi display issues..."

echo "Checking for under-voltage (causes rainbow flashes):"
if command -v vcgencmd >/dev/null 2>&1; then
    throttled=$(vcgencmd get_throttled | cut -d'=' -f2)
    if [ "$throttled" = "0x0" ]; then
        print_success "No under-voltage detected"
    else
        print_warning "Under-voltage detected: $throttled (this can cause display issues)"
    fi
fi

echo
echo "Checking for conflicting graphics configurations:"
if [ -f "/boot/config.txt" ]; then
    if grep -q "dtoverlay=vc4-kms-v3d" /boot/config.txt && grep -q "dtoverlay=vc4-fkms-v3d" /boot/config.txt; then
        print_error "Conflicting KMS overlays found in config.txt"
    elif grep -q "dtoverlay=vc4-kms-v3d" /boot/config.txt; then
        print_success "Full KMS enabled (good for kmsdrm driver)"
    elif grep -q "dtoverlay=vc4-fkms-v3d" /boot/config.txt; then
        print_warning "Fake KMS enabled (may cause issues with kmsdrm)"
    else
        print_status "Legacy graphics mode (use fbcon driver)"
    fi
fi

# 7. Provide solutions
print_status "7. Suggested solutions based on findings:"
echo

echo "IMMEDIATE TESTS TO TRY:"
echo "1. Test with software rendering (guaranteed to work):"
echo "   sudo systemctl stop flow-frame"
echo "   sudo SDL_VIDEODRIVER=software ./flow-frame"
echo "   # If this works, the issue is graphics driver configuration"
echo

echo "2. Test framebuffer mode:"
echo "   sudo SDL_VIDEODRIVER=fbcon ./flow-frame"
echo "   # If this works, switch service to use fbcon"
echo

echo "3. Force HDMI output:"
echo "   # Add to /boot/config.txt:"
echo "   hdmi_force_hotplug=1"
echo "   hdmi_safe=1"
echo "   # Then reboot"
echo

echo "4. Fix graphics driver conflicts:"
echo "   # Edit /boot/config.txt and choose ONE:"
echo "   # For modern KMS (use with kmsdrm):"
echo "   dtoverlay=vc4-kms-v3d"
echo "   # OR for legacy (use with fbcon):"
echo "   # (remove all dtoverlay=vc4 lines)"
echo

echo "5. Update service to use working driver:"
echo "   # If fbcon works:"
echo "   sudo sed -i 's/SDL_VIDEODRIVER=kmsdrm/SDL_VIDEODRIVER=fbcon/' /etc/systemd/system/flow-frame.service"
echo "   sudo systemctl daemon-reload && sudo systemctl restart flow-frame"
echo

print_success "Display diagnosis completed!"
print_status "Run the manual tests above to identify which graphics driver works." 