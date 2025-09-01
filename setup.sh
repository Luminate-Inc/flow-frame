#!/bin/bash

# Art Frame Setup Script for Linux
# This script sets up the complete development environment for the Art Frame project
#
# Usage:
#   sudo ./setup.sh                    # Recommended: auto-detects user via $SUDO_USER
#   SETUP_USER="username" sudo ./setup.sh  # Specify user explicitly
#   ./setup.sh                         # Run as regular user (limited package installation)
#
# The script will automatically:
# - Detect your Linux distribution and install appropriate packages
# - Install Go 1.23.1
# - Fix file permissions for the correct user
# - Build the Art Frame project

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
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

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to detect Linux distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

# Function to fix file permissions in art-frame directory
fix_file_permissions() {
    local target_user="$1"
    local art_frame_dir="$2"
    
    if [ -z "$target_user" ]; then
        print_error "No target user specified for permission fix"
        return 1
    fi
    
    if [ -z "$art_frame_dir" ]; then
        art_frame_dir="$(pwd)"
    fi
    
    print_status "Fixing file permissions in $art_frame_dir for user: $target_user"
    
    # Check if target user exists
    if ! id "$target_user" >/dev/null 2>&1; then
        print_error "User $target_user does not exist"
        return 1
    fi
    
    # Fix ownership of all files and directories recursively
    if [ "$EUID" -eq 0 ]; then
        # Running as root, can change ownership
        chown -R "$target_user:$(id -gn "$target_user")" "$art_frame_dir"
        print_success "Changed ownership of $art_frame_dir to $target_user"
    else
        # Not running as root, try to fix permissions without changing ownership
        find "$art_frame_dir" -type f -exec chmod 644 {} \; 2>/dev/null || true
        find "$art_frame_dir" -type d -exec chmod 755 {} \; 2>/dev/null || true
        find "$art_frame_dir" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
        print_success "Fixed file permissions in $art_frame_dir"
    fi
    
    # Ensure current user can read/write go.mod and other important files
    chmod 644 go.mod go.sum 2>/dev/null || true
    chmod +x setup.sh run-tests.sh 2>/dev/null || true
    
    print_status "File permissions fixed successfully"
}

# Function to validate if a user is real and valid
is_valid_user() {
    local user="$1"
    # Check user is not empty, not root, not UNKNOWN, and actually exists
    [ -n "$user" ] && [ "$user" != "root" ] && [ "$user" != "UNKNOWN" ] && [ "$user" != "unknown" ] && id "$user" >/dev/null 2>&1
}

# Function to get the actual user (not root) who should own files
get_actual_user() {
    # Debug: Show what we're working with
    print_status "Debug: SUDO_USER='${SUDO_USER:-}', SETUP_USER='${SETUP_USER:-}'"
    
    # Check if SETUP_USER environment variable is set and valid
    if [ -n "$SETUP_USER" ] && is_valid_user "$SETUP_USER"; then
        echo "$SETUP_USER"
        return 0
    fi
    
    # If SUDO_USER is set and valid, use that (user who ran sudo)
    if [ -n "$SUDO_USER" ] && is_valid_user "$SUDO_USER"; then
        echo "$SUDO_USER"
        return 0
    fi
    
    # Check if we're in a directory owned by a specific user
    local dir_owner=$(stat -c '%U' . 2>/dev/null || stat -f '%Su' . 2>/dev/null)
    if [ -n "$dir_owner" ] && is_valid_user "$dir_owner"; then
        echo "$dir_owner"
        return 0
    fi
    
    # Try to find the first non-system user (UID >= 1000)
    local first_user=$(awk -F: '$3 >= 1000 && $1 != "nobody" && $1 != "UNKNOWN" && $1 != "unknown" {print $1; exit}' /etc/passwd 2>/dev/null)
    if [ -n "$first_user" ] && is_valid_user "$first_user"; then
        print_warning "Auto-detected user: $first_user"
        echo "$first_user"
        return 0
    fi
    
    # Fall back to asking user (with timeout)
    print_status "Cannot automatically determine target user."
    print_status "Debug information:"
    print_status "  SUDO_USER: ${SUDO_USER:-'(not set)'}"
    print_status "  SETUP_USER: ${SETUP_USER:-'(not set)'}"
    print_status "  Current directory owner: $(stat -c '%U' . 2>/dev/null || stat -f '%Su' . 2>/dev/null || echo 'unknown')"
    print_status "Available users with UID >= 1000:"
    awk -F: '$3 >= 1000 && $1 != "nobody" && $1 != "UNKNOWN" {print "  - " $1 " (UID: " $3 ")"}' /etc/passwd 2>/dev/null || echo "  - (unable to list users)"
    print_status "Please enter the username who should own the art-frame files (or press Enter for auto-detect):"
    
    # Use timeout to avoid hanging in automated environments
    if command -v timeout >/dev/null 2>&1; then
        target_user=$(timeout 30 bash -c 'read -r input; echo "$input"' 2>/dev/null || echo "")
    else
        read -r target_user
    fi
    
    if [ -n "$target_user" ]; then
        echo "$target_user"
        return 0
    fi
    
    # Final fallback - use the first real user found
    if [ -n "$first_user" ] && is_valid_user "$first_user"; then
        print_warning "Using auto-detected user: $first_user"
        echo "$first_user"
        return 0
    fi
    
    # Last resort - suggest manual permission fix
    print_error "Could not determine a valid user for file ownership."
    print_status "You can manually fix permissions after setup with:"
    print_status "  sudo chown -R USERNAME:USERNAME /path/to/art-frame"
    print_status "Or set the user explicitly:"
    print_status "  SETUP_USER=\"username\" sudo ./setup.sh"
    
    return 1
}

# Function to install packages based on distro
install_packages() {
    local distro=$(detect_distro)
    print_status "Detected Linux distribution: $distro"
    
    case "$distro" in
        "ubuntu"|"debian")
            print_status "Updating package list..."
            sudo apt-get update -y
            
            print_status "Installing system packages..."
            sudo apt-get install -y \
                libsdl2-2.0-0 \
                libsdl2-ttf-2.0-0 \
                libwayland-client0 \
                libwayland-cursor0 \
                libwayland-egl1-mesa \
                libgl1-mesa-dri \
                libdrm2 \
                ffmpeg \
                libavcodec59 \
                libavformat59 \
                libavutil57 \
                libswscale6 \
                libavcodec-dev \
                libavformat-dev \
                libavutil-dev \
                libswscale-dev \
                libavfilter-dev \
                ca-certificates \
                wget \
                curl \
                build-essential \
                git \
                pkg-config \
                libsdl2-dev \
                libsdl2-ttf-dev \
                awscli \
                python3
            ;;
        "fedora"|"rhel"|"centos")
            print_status "Installing system packages..."
            sudo dnf install -y \
                SDL2 \
                SDL2_ttf \
                wayland \
                mesa-libGL \
                libdrm \
                ffmpeg \
                ffmpeg-devel \
                ca-certificates \
                wget \
                curl \
                gcc \
                gcc-c++ \
                git \
                pkg-config \
                SDL2-devel \
                SDL2_ttf-devel \
                awscli \
                python3
            ;;
        "arch")
            print_status "Installing system packages..."
            sudo pacman -S --noconfirm \
                sdl2 \
                sdl2_ttf \
                wayland \
                mesa \
                libdrm \
                ffmpeg \
                ca-certificates \
                wget \
                curl \
                base-devel \
                git \
                pkg-config \
                aws-cli \
                python
            ;;
        *)
            print_error "Unsupported Linux distribution: $distro"
            print_warning "Please install the packages manually from packages.runtime.txt"
            ;;
    esac
}

# Function to verify and fix pkg-config for FFmpeg
verify_ffmpeg_pkgconfig() {
    print_status "Verifying FFmpeg pkg-config setup..."
    
    # Test if pkg-config can find FFmpeg libraries
    local missing_libs=()
    
    for lib in libavformat libavcodec libavutil libswscale; do
        if ! pkg-config --exists "$lib" 2>/dev/null; then
            missing_libs+=("$lib")
        fi
    done
    
    if [ ${#missing_libs[@]} -eq 0 ]; then
        print_success "All FFmpeg pkg-config files found"
        return 0
    fi
    
    print_warning "Missing pkg-config files for: ${missing_libs[*]}"
    
    # Try to find and add common pkg-config paths
    local common_paths=(
        "/usr/lib/pkgconfig"
        "/usr/lib/x86_64-linux-gnu/pkgconfig"
        "/usr/lib64/pkgconfig"
        "/usr/local/lib/pkgconfig"
        "/opt/ffmpeg/lib/pkgconfig"
    )
    
    for path in "${common_paths[@]}"; do
        if [ -d "$path" ]; then
            export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:+$PKG_CONFIG_PATH:}$path"
        fi
    done
    
    print_status "Updated PKG_CONFIG_PATH: $PKG_CONFIG_PATH"
    
    # Test again after updating paths
    missing_libs=()
    for lib in libavformat libavcodec libavutil libswscale; do
        if ! pkg-config --exists "$lib" 2>/dev/null; then
            missing_libs+=("$lib")
        fi
    done
    
    if [ ${#missing_libs[@]} -eq 0 ]; then
        print_success "FFmpeg pkg-config setup successful"
        
        # Add to bashrc for persistence
        if ! grep -q "PKG_CONFIG_PATH.*ffmpeg" ~/.bashrc 2>/dev/null; then
            echo "export PKG_CONFIG_PATH=\"$PKG_CONFIG_PATH\"" >> ~/.bashrc
        fi
        
        return 0
    else
        print_warning "Still missing pkg-config files for: ${missing_libs[*]}"
        print_status "Manual installation may be required"
        return 1
    fi
}

# Function to install Go 1.23.1
install_go() {
    local go_version="1.23.1"
    local go_arch
    local go_dir="/usr/local/go"
    
    # Detect architecture
    case "$(uname -m)" in
        "x86_64") go_arch="amd64" ;;
        "aarch64"|"arm64") go_arch="arm64" ;;
        "armv7l") go_arch="armv6l" ;;
        *) 
            print_error "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac
    
    print_status "Installing Go $go_version for $go_arch..."
    
    # Check if Go is already installed with correct version
    if command_exists go; then
        local current_version=$(go version | grep -oE 'go[0-9]+\.[0-9]+\.[0-9]+' | sed 's/go//')
        if [ "$current_version" = "$go_version" ]; then
            print_success "Go $go_version is already installed"
            return 0
        else
            print_warning "Go $current_version is installed, but we need $go_version"
        fi
    fi
    
    # Download and install Go
    local go_tarball="go${go_version}.linux-${go_arch}.tar.gz"
    local go_url="https://golang.org/dl/${go_tarball}"
    
    print_status "Downloading Go $go_version..."
    wget -q "$go_url" -O "/tmp/${go_tarball}"
    
    print_status "Installing Go to $go_dir..."
    sudo rm -rf "$go_dir"
    sudo tar -C /usr/local -xzf "/tmp/${go_tarball}"
    
    # Clean up
    rm "/tmp/${go_tarball}"
    
    print_success "Go $go_version installed successfully"
}

# Function to setup Go environment
setup_go_env() {
    print_status "Setting up Go environment..."
    
    # Add Go to PATH if not already there
    if ! echo "$PATH" | grep -q "/usr/local/go/bin"; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
        echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
        export PATH=$PATH:/usr/local/go/bin
    fi
    
    # Set GOPATH if not set
    if [ -z "$GOPATH" ]; then
        echo 'export GOPATH=$HOME/go' >> ~/.bashrc
        echo 'export GOPATH=$HOME/go' >> ~/.profile
        export GOPATH=$HOME/go
    fi
    
    # Add GOPATH/bin to PATH
    if ! echo "$PATH" | grep -q "$GOPATH/bin"; then
        echo 'export PATH=$PATH:$GOPATH/bin' >> ~/.bashrc
        echo 'export PATH=$PATH:$GOPATH/bin' >> ~/.profile
        export PATH=$PATH:$GOPATH/bin
    fi
    
    print_success "Go environment configured"
}

# Function to install Go dependencies
install_go_deps() {
    print_status "Installing Go dependencies..."
    
    # Verify go.mod is readable
    if [ ! -r "go.mod" ]; then
        print_error "Cannot read go.mod file. Check file permissions."
        print_status "If you see this error, try running: sudo chown -R \$(whoami) ."
        exit 1
    fi
    
    # Verify Go can find the module
    print_status "Verifying Go module configuration..."
    if ! go list -m >/dev/null 2>&1; then
        print_error "Go cannot read the module. This may be a permission issue."
        print_status "Current user: $(whoami)"
        print_status "Go module file permissions:"
        ls -la go.mod go.sum 2>/dev/null || true
        exit 1
    fi
    
    # Tidy up dependencies and download them
    go mod tidy
    go mod download all
    
    print_success "Go dependencies installed"
}

# Function to run comprehensive build diagnostics
run_build_diagnostics() {
    print_status "Running comprehensive build diagnostics..."
    
    # 1. Check Go environment
    print_status "Go Environment Check:"
    print_status "  Go version: $(go version)"
    print_status "  GOPATH: ${GOPATH:-'not set'}"
    print_status "  GOROOT: $(go env GOROOT)"
    print_status "  CGO_ENABLED: $(go env CGO_ENABLED)"
    
    # 2. Check pkg-config setup
    print_status "pkg-config Check:"
    if command -v pkg-config >/dev/null 2>&1; then
        print_status "  pkg-config version: $(pkg-config --version)"
        print_status "  PKG_CONFIG_PATH: ${PKG_CONFIG_PATH:-'not set'}"
    else
        print_error "  pkg-config not found!"
        return 1
    fi
    
    # 3. Check Go module
    print_status "Go Module Check:"
    print_status "  Module name: $(go list -m 2>/dev/null || echo 'ERROR: Cannot read module')"
    print_status "  Go version in mod: $(grep '^go ' go.mod 2>/dev/null || echo 'ERROR: Cannot read go.mod')"
    
    # 4. Check dependencies
    print_status "Dependency Check:"
    go list -m all 2>/dev/null | head -10 | while read line; do
        print_status "  $line"
    done
    
    return 0
}

# Function to test CGO and FFmpeg compilation
test_cgo_ffmpeg() {
    print_status "Testing CGO and FFmpeg compilation..."
    
    # Run diagnostics first
    run_build_diagnostics
    
    # Test if pkg-config works with Go
    export CGO_ENABLED=1
    
    # Simple test to see if CGO can find FFmpeg libraries
    cat > /tmp/test_ffmpeg.go << 'EOF'
package main

/*
#cgo pkg-config: libavformat libavcodec libavutil

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>

int test_ffmpeg() {
    return LIBAVCODEC_VERSION_MAJOR;
}
*/
import "C"

import "fmt"

func main() {
    fmt.Printf("FFmpeg version: %d\n", int(C.test_ffmpeg()))
}
EOF
    
    print_status "Attempting CGO compilation test..."
    
    # Capture build output for diagnosis
    build_output=$(go build -v -o /tmp/test_ffmpeg /tmp/test_ffmpeg.go 2>&1)
    build_result=$?
    
    if [ $build_result -eq 0 ] && [ -f "/tmp/test_ffmpeg" ]; then
        print_success "CGO and FFmpeg compilation test successful"
        
        # Test execution
        if /tmp/test_ffmpeg 2>/dev/null; then
            print_success "FFmpeg runtime test successful"
        else
            print_warning "FFmpeg compilation OK but runtime test failed"
        fi
        
        rm -f /tmp/test_ffmpeg /tmp/test_ffmpeg.go
        return 0
    else
        print_error "CGO/FFmpeg compilation test failed"
        print_status "Build output:"
        echo "$build_output" | while IFS= read -r line; do
            print_status "  $line"
        done
        
        print_status "Attempting to fix with additional environment variables..."
        
        # Try with additional CGO flags
        export CGO_CFLAGS="-I/usr/include/ffmpeg -I/usr/local/include -I/usr/include/x86_64-linux-gnu"
        export CGO_LDFLAGS="-L/usr/lib -L/usr/local/lib -L/usr/lib/x86_64-linux-gnu -lavformat -lavcodec -lavutil -lswscale"
        
        print_status "Retrying with manual CGO flags..."
        print_status "  CGO_CFLAGS: $CGO_CFLAGS"
        print_status "  CGO_LDFLAGS: $CGO_LDFLAGS"
        
        build_output2=$(go build -v -o /tmp/test_ffmpeg /tmp/test_ffmpeg.go 2>&1)
        build_result2=$?
        
        if [ $build_result2 -eq 0 ] && [ -f "/tmp/test_ffmpeg" ]; then
            print_success "CGO compilation successful with manual flags"
            
            # Add these to environment for main build
            echo "export CGO_CFLAGS=\"$CGO_CFLAGS\"" >> ~/.bashrc
            echo "export CGO_LDFLAGS=\"$CGO_LDFLAGS\"" >> ~/.bashrc
            
            rm -f /tmp/test_ffmpeg /tmp/test_ffmpeg.go
            return 0
        else
            print_error "CGO/FFmpeg compilation still failing even with manual flags"
            print_status "Second attempt output:"
            echo "$build_output2" | while IFS= read -r line; do
                print_status "  $line"
            done
            
            print_status "Suggestions:"
            print_status "  1. Install FFmpeg development packages: sudo apt-get install libavformat-dev libavcodec-dev"
            print_status "  2. Check if pkg-config can find FFmpeg: pkg-config --libs libavformat"
            print_status "  3. Manual build may be required"
            
            rm -f /tmp/test_ffmpeg.go
            return 1
        fi
    fi
}

# Function to detect Raspberry Pi and configure graphics
configure_raspberry_pi_graphics() {
    # Check if this is a Raspberry Pi
    if [ -f "/proc/device-tree/model" ]; then
        local rpi_model=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')
        if echo "$rpi_model" | grep -qi "raspberry pi"; then
            print_status "Detected Raspberry Pi: $rpi_model"
            
            # Enable GPU support
            if [ -f "/boot/config.txt" ]; then
                print_status "Configuring Raspberry Pi GPU settings..."
                
                # Backup config.txt
                sudo cp /boot/config.txt /boot/config.txt.backup.$(date +%Y%m%d_%H%M%S)
                
                # Set initial GPU memory (will be optimized later for stability)
                if ! grep -q "^gpu_mem=" /boot/config.txt; then
                    echo "gpu_mem=64" | sudo tee -a /boot/config.txt
                    print_status "Added gpu_mem=64 to /boot/config.txt"
                else
                    print_status "GPU memory setting will be optimized for stability"
                fi
                
                # Note: KMS driver will be configured later in the display fix function
                print_status "Graphics driver will be configured for stability"
                
                # Enable framebuffer
                if ! grep -q "^framebuffer_width=" /boot/config.txt; then
                    echo "framebuffer_width=1920" | sudo tee -a /boot/config.txt
                    echo "framebuffer_height=1080" | sudo tee -a /boot/config.txt
                    print_status "Added framebuffer resolution settings"
                fi
            fi
            
            # Set up framebuffer permissions
            if [ -c "/dev/fb0" ]; then
                sudo chmod 666 /dev/fb0
                print_status "Set framebuffer permissions"
            fi
            
            # Add user to video group
            sudo usermod -a -G video root 2>/dev/null || true
            sudo usermod -a -G video $(whoami) 2>/dev/null || true
            
            return 0
        fi
    fi
    return 1
}

# Function to fix Raspberry Pi rainbow flash/display issues
fix_raspberry_pi_display_issues() {
    print_status "Diagnosing and fixing Raspberry Pi display issues..."
    
    if [ ! -f "/proc/device-tree/model" ] || ! grep -qi "raspberry pi" /proc/device-tree/model; then
        print_status "Not a Raspberry Pi, skipping Pi-specific fixes"
        return 0
    fi
    
    local rpi_model=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')
    print_status "Raspberry Pi model: $rpi_model"
    
    # Check for common issues
    print_status "Checking for common display issues..."
    
    # 1. Check power supply (under-voltage detection)
    if [ -f "/opt/vc/bin/vcgencmd" ]; then
        local throttled=$(/opt/vc/bin/vcgencmd get_throttled 2>/dev/null | cut -d'=' -f2)
        if [ "$throttled" != "0x0" ]; then
            print_warning "Under-voltage detected! This causes rainbow flashes."
            print_status "Current throttling status: $throttled"
            print_status "Solutions:"
            echo "  - Use official Pi power supply (5V 3A for Pi 4)"
            echo "  - Check USB cable quality"
            echo "  - Reduce GPU memory if using battery power"
        else
            print_success "Power supply appears adequate"
        fi
        
        # Check GPU memory
        local gpu_mem=$(/opt/vc/bin/vcgencmd get_mem gpu 2>/dev/null | cut -d'=' -f2 | cut -d'M' -f1)
        print_status "Current GPU memory: ${gpu_mem}MB"
        
        if [ "$gpu_mem" -gt 256 ]; then
            print_warning "GPU memory very high ($gpu_mem MB) - may cause issues"
            print_status "Reducing GPU memory to 64MB for stability..."
            sudo sed -i 's/^gpu_mem=.*/gpu_mem=64/' /boot/config.txt
        elif [ "$gpu_mem" -lt 32 ]; then
            print_warning "GPU memory very low ($gpu_mem MB) - may cause issues"
            print_status "Increasing GPU memory to 64MB..."
            sudo sed -i 's/^gpu_mem=.*/gpu_mem=64/' /boot/config.txt
        fi
    fi
    
    # 2. Fix graphics driver conflicts
    print_status "Fixing graphics driver configuration..."
    
    # Backup config.txt if not already backed up
    if [ ! -f "/boot/config.txt.rainbow_fix_backup" ]; then
        sudo cp /boot/config.txt /boot/config.txt.rainbow_fix_backup
    fi
    
    # Remove conflicting graphics settings first
    sudo sed -i '/^dtoverlay=vc4-fkms-v3d/d' /boot/config.txt
    sudo sed -i '/^dtoverlay=vc4-kms-v3d/d' /boot/config.txt
    
    # For Pi 4, configure for stable graphics (prefer KMS when possible)
    if echo "$rpi_model" | grep -qi "raspberry pi 4"; then
        print_status "Configuring Pi 4 for stable graphics..."
        
        # Check if we want KMS or legacy mode
        if [ -d "/dev/dri" ] && ls /dev/dri/card* >/dev/null 2>&1; then
            print_success "KMS/DRM detected - enabling KMS mode for better performance"
            echo "dtoverlay=vc4-kms-v3d" | sudo tee -a /boot/config.txt
            print_status "RECOMMENDED: Use SDL_VIDEODRIVER=kmsdrm for best performance"
        else
            print_warning "No KMS/DRM detected - will configure for legacy mode"
            print_status "After reboot, KMS/DRM may become available"
        fi
        
        # Use legacy graphics for stability
        if ! grep -q "^gpu_mem=64" /boot/config.txt; then
            echo "gpu_mem=64" | sudo tee -a /boot/config.txt
        fi
        
        # Force HDMI output if connected
        if ! grep -q "^hdmi_force_hotplug=1" /boot/config.txt; then
            echo "hdmi_force_hotplug=1" | sudo tee -a /boot/config.txt
        fi
        
        # Set safe display mode
        if ! grep -q "^hdmi_safe=1" /boot/config.txt; then
            echo "hdmi_safe=1" | sudo tee -a /boot/config.txt
        fi
        
        # Disable overscan
        if ! grep -q "^disable_overscan=1" /boot/config.txt; then
            echo "disable_overscan=1" | sudo tee -a /boot/config.txt
        fi
        
        print_status "Applied Pi 4 legacy graphics configuration"
    fi
    
    # 3. Configure framebuffer for console mode
    print_status "Configuring framebuffer settings..."
    
    # Set console framebuffer settings
    if ! grep -q "^framebuffer_width=" /boot/config.txt; then
        echo "framebuffer_width=1920" | sudo tee -a /boot/config.txt
        echo "framebuffer_height=1080" | sudo tee -a /boot/config.txt
    fi
    
    # Set boot config for console
    if ! grep -q "^boot_delay=1" /boot/config.txt; then
        echo "boot_delay=1" | sudo tee -a /boot/config.txt
    fi
    
    # 4. Update firmware if very old
    print_status "Checking firmware version..."
    if [ -f "/opt/vc/bin/vcgencmd" ]; then
        local firmware_version=$(/opt/vc/bin/vcgencmd version 2>/dev/null | head -n1 || echo "unknown")
        print_status "Firmware: $firmware_version"
    fi
    
    print_success "Raspberry Pi display fixes applied"
    
    # Show what was changed
    print_status "Configuration changes made:"
    echo "  - Set gpu_mem=64 (safe value)"
    echo "  - Enabled hdmi_force_hotplug=1"
    echo "  - Enabled hdmi_safe=1 (conservative display mode)"
    echo "  - Disabled overscan"
    if [ -d "/dev/dri" ] && ls /dev/dri/card* >/dev/null 2>&1; then
        echo "  - Enabled KMS drivers (modern graphics with hardware acceleration)"
        echo "  - Use SDL_VIDEODRIVER=kmsdrm for best performance"
    else
        echo "  - Using legacy mode (maximum compatibility)"
        echo "  - Use SDL_VIDEODRIVER=fbcon or SDL_VIDEODRIVER=software"
    fi
    echo "  - Set framebuffer resolution to 1920x1080"
    
    return 0
}

# Function to install DietPi graphics packages
install_dietpi_graphics() {
    print_status "Installing DietPi graphics support..."
    
    # Install essential graphics packages
    sudo apt-get update -y
    sudo apt-get install -y \
        xserver-xorg-legacy \
        xserver-xorg-video-fbdev \
        fbset \
        console-setup \
        keyboard-configuration
    
    # Try to install X11 minimal (may fail on headless)
    sudo apt-get install -y \
        xinit \
        xorg \
        openbox \
        x11-xserver-utils || print_warning "X11 packages installation failed (may be headless setup)"
    
    print_status "Graphics packages installed"
}

# Function to detect and configure display environment
setup_display_environment() {
    print_status "Detecting and configuring display environment..."
    
    # Configure Raspberry Pi specific settings first
    configure_raspberry_pi_graphics
    
    # Fix common Raspberry Pi display issues (rainbow flashes, etc.)
    if [ -f "/proc/device-tree/model" ] && grep -qi "raspberry pi" /proc/device-tree/model; then
        fix_raspberry_pi_display_issues
    fi
    
    # Install DietPi graphics support
    install_dietpi_graphics
    
    # Detect display server type
    local display_type=""
    local display_value=""
    local sdl_driver=""
    
    # For Raspberry Pi, prioritize KMS/DRM over legacy framebuffer
    if [ -f "/proc/device-tree/model" ] && grep -qi "raspberry pi" /proc/device-tree/model; then
        if [ -d "/dev/dri" ] && ls /dev/dri/card* >/dev/null 2>&1; then
            display_type="Raspberry Pi KMS/DRM"
            display_value=":0"
            sdl_driver="kmsdrm"
            print_status "Detected: Raspberry Pi with KMS/DRM (preferred)"
        elif [ -d "/sys/class/drm" ] && ls /sys/class/drm/card* >/dev/null 2>&1; then
            display_type="Raspberry Pi DRM"
            display_value=":0"
            sdl_driver="kmsdrm"
            print_status "Detected: Raspberry Pi with DRM support"
        elif [ -c "/dev/fb0" ]; then
            display_type="Raspberry Pi Framebuffer"
            display_value=":0"
            sdl_driver="fbcon"
            print_status "Detected: Raspberry Pi with framebuffer (legacy mode)"
            print_warning "Consider using KMS/DRM for better performance"
        elif [ -d "/sys/class/graphics" ]; then
            display_type="Raspberry Pi Graphics System"
            display_value=":0"
            sdl_driver="kmsdrm"
            print_status "Detected: Raspberry Pi with graphics support (trying KMS/DRM)"
        else
            display_type="Raspberry Pi Software Fallback"
            display_value=":0"
            sdl_driver="software"
            print_warning "Raspberry Pi detected but no hardware graphics found, using software fallback"
            print_status "Consider configuring graphics with: sudo raspi-config"
        fi
    # Check for X11
    elif pgrep -x "X" >/dev/null 2>&1 || pgrep -x "Xorg" >/dev/null 2>&1; then
        display_type="X11"
        display_value=":0"
        sdl_driver="x11"
        print_status "Detected: X11 display server running"
    # Check for Wayland
    elif pgrep -x "weston" >/dev/null 2>&1 || pgrep -x "sway" >/dev/null 2>&1 || [ -n "$WAYLAND_DISPLAY" ]; then
        display_type="Wayland"
        display_value="${WAYLAND_DISPLAY:-wayland-0}"
        sdl_driver="wayland"
        print_status "Detected: Wayland display server running"
    # Check for framebuffer
    elif [ -c "/dev/fb0" ]; then
        display_type="Framebuffer"
        display_value=":0"
        sdl_driver="fbcon"
        print_status "Detected: Framebuffer available (/dev/fb0)"
    # Check for KMS/DRM
    elif [ -d "/dev/dri" ] && ls /dev/dri/card* >/dev/null 2>&1; then
        display_type="KMS/DRM"
        display_value=":0"
        sdl_driver="kmsdrm"
        print_status "Detected: KMS/DRM available"
    else
        # Try to detect any available graphics capability
        if [ -d "/dev/dri" ] && ls /dev/dri/card* >/dev/null 2>&1; then
            display_type="Generic KMS/DRM"
            display_value=":0"
            sdl_driver="kmsdrm"
            print_status "Detected: Generic system with KMS/DRM support"
        elif [ -d "/sys/class/drm" ] && ls /sys/class/drm/card* >/dev/null 2>&1; then
            display_type="Generic DRM"
            display_value=":0"
            sdl_driver="kmsdrm"
            print_status "Detected: Generic system with DRM support"
        elif [ -c "/dev/fb0" ]; then
            display_type="Generic Framebuffer"
            display_value=":0"
            sdl_driver="fbcon"
            print_status "Detected: Generic system with framebuffer"
        else
            display_type="Software Fallback"
            display_value=":0"
            sdl_driver="software"
            print_warning "No hardware graphics detected, using software rendering"
        fi
    fi
    
    # Check GPU memory on Raspberry Pi
    if [ -f "/opt/vc/bin/vcgencmd" ]; then
        local gpu_mem=$(/opt/vc/bin/vcgencmd get_mem gpu 2>/dev/null | cut -d'=' -f2 | cut -d'M' -f1)
        print_status "Raspberry Pi GPU memory: ${gpu_mem:-unknown}MB"
        
        if [ -n "$gpu_mem" ] && [ "$gpu_mem" -lt 64 ]; then
            print_warning "GPU memory is low ($gpu_mem MB). Consider increasing to 64MB or higher."
            print_status "Edit /boot/config.txt and add: gpu_mem=64"
        fi
    fi
    
    # Set display environment variables
    export DISPLAY="$display_value"
    export SDL_VIDEODRIVER="$sdl_driver"
    
    print_success "Display environment configured:"
    print_status "  Display Type: $display_type"
    print_status "  DISPLAY: $display_value"
    print_status "  SDL_VIDEODRIVER: $sdl_driver"
    
    # Export for service file creation
    DETECTED_DISPLAY="$display_value"
    DETECTED_SDL_DRIVER="$sdl_driver"
    DETECTED_DISPLAY_TYPE="$display_type"
}

# Function to test KMS/DRM support
test_kms_drm_support() {
    print_status "Testing KMS/DRM support..."
    
    # Check for DRI devices
    if [ -d "/dev/dri" ]; then
        print_status "DRI devices:"
        ls -la /dev/dri/ | while IFS= read -r line; do
            print_status "  $line"
        done
        
        # Check permissions
        if ls /dev/dri/card* >/dev/null 2>&1; then
            for card in /dev/dri/card*; do
                if [ -r "$card" ]; then
                    print_success "  $card is readable"
                else
                    print_warning "  $card is not readable - may need permission fix"
                    sudo chmod 666 "$card" 2>/dev/null || true
                fi
            done
        fi
    else
        print_warning "No /dev/dri directory found"
    fi
    
    # Check DRM modules
    print_status "DRM-related modules:"
    if lsmod | grep -E "(drm|vc4)"; then
        lsmod | grep -E "(drm|vc4)" | while IFS= read -r line; do
            print_status "  $line"
        done
    else
        print_warning "  No DRM modules loaded"
    fi
    
    # Check DRM capabilities in sysfs
    if [ -d "/sys/class/drm" ]; then
        print_status "DRM devices in sysfs:"
        for drm_dev in /sys/class/drm/card*; do
            if [ -d "$drm_dev" ]; then
                card_name=$(basename "$drm_dev")
                print_status "  $card_name"
                if [ -f "$drm_dev/device/driver" ]; then
                    driver_path=$(readlink "$drm_dev/device/driver" 2>/dev/null || echo "unknown")
                    driver_name=$(basename "$driver_path")
                    print_status "    Driver: $driver_name"
                fi
            fi
        done
    else
        print_warning "No /sys/class/drm found"
    fi
}

# Function to test display configuration
test_display_config() {
    print_status "Testing display configuration..."
    
    # Test KMS/DRM first
    test_kms_drm_support
    
    # Simple SDL test
    cat > /tmp/test_display.go << 'EOF'
package main

import (
    "fmt"
    "os"
    "github.com/veandco/go-sdl2/sdl"
)

func main() {
    // Set the detected SDL driver
    if driver := os.Getenv("SDL_VIDEODRIVER"); driver != "" {
        fmt.Printf("Testing with SDL_VIDEODRIVER: %s\n", driver)
    }
    
    if err := sdl.Init(sdl.INIT_VIDEO); err != nil {
        fmt.Printf("SDL Init failed: %v\n", err)
        return
    }
    defer sdl.Quit()
    
    // Get video driver info
    driver := sdl.GetCurrentVideoDriver()
    fmt.Printf("Current video driver: %s\n", driver)
    
    // Get display info
    numDisplays, err := sdl.GetNumVideoDisplays()
    if err != nil {
        fmt.Printf("GetNumVideoDisplays failed: %v\n", err)
        return
    }
    
    fmt.Printf("Number of displays: %d\n", numDisplays)
    
    if numDisplays > 0 {
        mode, err := sdl.GetCurrentDisplayMode(0)
        if err != nil {
            fmt.Printf("GetCurrentDisplayMode failed: %v\n", err)
            return
        }
        fmt.Printf("Display 0: %dx%d@%dHz\n", mode.W, mode.H, mode.RefreshRate)
    }
    
    fmt.Println("Display test completed successfully")
}
EOF
    
    # Set the detected driver for testing
    export SDL_VIDEODRIVER="$DETECTED_SDL_DRIVER"
    
    # Try to compile and run the test
    if go build -o /tmp/test_display /tmp/test_display.go 2>/dev/null; then
        print_status "Running display test with $DETECTED_SDL_DRIVER driver..."
        local test_output
        test_output=$(timeout 10 /tmp/test_display 2>&1 || echo "Test timed out or failed")
        
        echo "$test_output" | while IFS= read -r line; do
            print_status "  $line"
        done
        
        if echo "$test_output" | grep -q "Display test completed successfully"; then
            print_success "Display test passed with $DETECTED_SDL_DRIVER driver"
        else
            print_warning "Display test failed with $DETECTED_SDL_DRIVER driver - trying fallbacks"
            
            # Try alternative drivers
            for fallback_driver in kmsdrm software x11; do
                if [ "$fallback_driver" != "$DETECTED_SDL_DRIVER" ]; then
                    print_status "Testing fallback driver: $fallback_driver"
                    export SDL_VIDEODRIVER="$fallback_driver"
                    test_output=$(timeout 5 /tmp/test_display 2>&1 || echo "Test failed")
                    
                    if echo "$test_output" | grep -q "Display test completed successfully"; then
                        print_success "Fallback driver $fallback_driver works!"
                        print_status "Consider using: SDL_VIDEODRIVER=$fallback_driver"
                        break
                    fi
                fi
            done
        fi
        
        rm -f /tmp/test_display /tmp/test_display.go
    else
        print_warning "Could not compile display test - skipping"
        rm -f /tmp/test_display.go
    fi
}

# Function to diagnose framebuffer status
diagnose_framebuffer() {
    print_status "Diagnosing framebuffer status..."
    
    # First check for modern KMS/DRM (recommended)
    print_status "Checking modern graphics (KMS/DRM) - RECOMMENDED:"
    if [ -d "/dev/dri" ] && ls /dev/dri/card* >/dev/null 2>&1; then
        print_success "  KMS/DRM available - USE THIS INSTEAD:"
        echo "    SDL_VIDEODRIVER=kmsdrm"
        echo "    Test with: sudo ./setup.sh --test-kmsdrm"
        ls -la /dev/dri/ | while IFS= read -r line; do
            print_status "    $line"
        done
    else
        print_warning "  No KMS/DRM found - falling back to legacy framebuffer"
    fi
    
    echo
    print_status "Legacy framebuffer devices:"
    if ls /dev/fb* 2>/dev/null; then
        ls -la /dev/fb* | while IFS= read -r line; do
            print_status "  $line"
        done
    else
        print_warning "  No framebuffer devices found"
    fi
    
    # Check loaded modules
    print_status "Framebuffer-related modules:"
    if lsmod | grep -E "(fb|vc4|drm)"; then
        lsmod | grep -E "(fb|vc4|drm)" | while IFS= read -r line; do
            print_status "  $line"
        done
    else
        print_warning "  No framebuffer modules loaded (may be built into kernel)"
    fi
    
    # Check if framebuffer support is built into kernel
    print_status "Kernel framebuffer support:"
    if [ -d "/sys/class/graphics" ]; then
        print_success "  /sys/class/graphics exists - framebuffer support available"
        if ls /sys/class/graphics/fb* 2>/dev/null; then
            for fb_sys in /sys/class/graphics/fb*; do
                if [ -d "$fb_sys" ]; then
                    fb_name=$(basename "$fb_sys")
                    print_status "  Found: $fb_name"
                    if [ -f "$fb_sys/name" ]; then
                        fb_driver=$(cat "$fb_sys/name" 2>/dev/null || echo "unknown")
                        print_status "    Driver: $fb_driver"
                    fi
                fi
            done
        else
            print_warning "  No framebuffer devices found in /sys/class/graphics"
        fi
    else
        print_warning "  /sys/class/graphics not found - limited framebuffer support"
    fi
    
    # Check available modules in the system
    print_status "Available framebuffer modules:"
    if find /lib/modules/$(uname -r) -name "*fb*" -type f 2>/dev/null | head -5; then
        find /lib/modules/$(uname -r) -name "*fb*" -type f 2>/dev/null | head -5 | while IFS= read -r module; do
            module_name=$(basename "$module" .ko)
            print_status "  $module_name"
        done
    else
        print_warning "  No framebuffer modules found in /lib/modules/$(uname -r)"
    fi
    
    # Check boot configuration (Raspberry Pi)
    if [ -f "/boot/config.txt" ]; then
        print_status "Graphics configuration in /boot/config.txt:"
        if grep -E "(gpu_mem|dtoverlay=|framebuffer|hdmi)" /boot/config.txt 2>/dev/null; then
            grep -E "(gpu_mem|dtoverlay=|framebuffer|hdmi)" /boot/config.txt | while IFS= read -r line; do
                print_status "  $line"
            done
        else
            print_warning "  No graphics configuration found"
        fi
    fi
    
    # Check kernel command line
    if [ -f "/proc/cmdline" ]; then
        print_status "Kernel command line:"
        print_status "  $(cat /proc/cmdline)"
    fi
    
    # Try to get framebuffer info if available
    if [ -c "/dev/fb0" ] && command -v fbset >/dev/null 2>&1; then
        print_status "Framebuffer information:"
        fbset -s 2>/dev/null | while IFS= read -r line; do
            print_status "  $line"
        done
    fi
}

# Function to enable framebuffer
enable_framebuffer() {
    print_status "Enabling framebuffer support..."
    
    # Check if this is a Raspberry Pi
    if [ -f "/proc/device-tree/model" ] && grep -qi "raspberry pi" /proc/device-tree/model; then
        print_status "Configuring Raspberry Pi framebuffer..."
        
        # Ensure framebuffer modules are loaded (if available)
        print_status "Loading framebuffer modules..."
        
        # Try to load framebuffer modules (may be built-in)
        sudo modprobe fb 2>/dev/null || print_status "fb module: already loaded or built-in"
        sudo modprobe fbcon 2>/dev/null || print_status "fbcon module: already loaded or built-in"
        sudo modprobe vc4 2>/dev/null || print_status "vc4 module: already loaded or built-in"
        
        # Check if framebuffer support is available in kernel
        if [ -d "/sys/class/graphics" ]; then
            print_success "Framebuffer support detected in kernel"
        else
            print_warning "Framebuffer support may not be available in this kernel"
        fi
        
        # Configure boot settings for framebuffer
        if [ -f "/boot/config.txt" ]; then
            print_status "Updating /boot/config.txt for framebuffer support..."
            
            # Backup first
            sudo cp /boot/config.txt /boot/config.txt.fb_backup.$(date +%Y%m%d_%H%M%S)
            
            # Remove any conflicting graphics overlays
            sudo sed -i '/^dtoverlay=vc4-kms-v3d/d' /boot/config.txt
            sudo sed -i '/^dtoverlay=vc4-fkms-v3d/d' /boot/config.txt
            
            # Enable legacy graphics for framebuffer access
            if ! grep -q "^gpu_mem=" /boot/config.txt; then
                echo "gpu_mem=64" | sudo tee -a /boot/config.txt
            fi
            
            # Force framebuffer console
            if ! grep -q "^framebuffer_width=" /boot/config.txt; then
                echo "framebuffer_width=1920" | sudo tee -a /boot/config.txt
                echo "framebuffer_height=1080" | sudo tee -a /boot/config.txt
                echo "framebuffer_depth=32" | sudo tee -a /boot/config.txt
            fi
            
            # Enable console on framebuffer
            if ! grep -q "^enable_uart=1" /boot/config.txt; then
                echo "enable_uart=1" | sudo tee -a /boot/config.txt
            fi
            
            # Force HDMI output
            if ! grep -q "^hdmi_force_hotplug=1" /boot/config.txt; then
                echo "hdmi_force_hotplug=1" | sudo tee -a /boot/config.txt
            fi
            
            # Disable KMS which can interfere with direct framebuffer access
            if ! grep -q "^disable_fw_kms_setup=1" /boot/config.txt; then
                echo "disable_fw_kms_setup=1" | sudo tee -a /boot/config.txt
            fi
            
            print_status "Boot configuration updated for framebuffer"
        fi
        
        # Update command line for framebuffer console
        if [ -f "/boot/cmdline.txt" ]; then
            print_status "Updating kernel command line for framebuffer console..."
            
            # Backup cmdline.txt
            sudo cp /boot/cmdline.txt /boot/cmdline.txt.fb_backup.$(date +%Y%m%d_%H%M%S)
            
            # Ensure fbcon is enabled
            if ! grep -q "fbcon=map:0" /boot/cmdline.txt; then
                sudo sed -i 's/$/ fbcon=map:0/' /boot/cmdline.txt
            fi
            
            # Remove any splash screen that might interfere
            sudo sed -i 's/splash//g' /boot/cmdline.txt
            sudo sed -i 's/quiet//g' /boot/cmdline.txt
            
            print_status "Kernel command line updated"
        fi
        
    else
        # Non-Raspberry Pi systems
        print_status "Configuring framebuffer for generic Linux..."
        
        # Try to load framebuffer modules (may not be available)
        sudo modprobe fb 2>/dev/null || print_status "fb module: not available or built-in"
        sudo modprobe fbcon 2>/dev/null || print_status "fbcon module: not available or built-in"
        sudo modprobe vga16fb 2>/dev/null || print_status "vga16fb module: not available"
        sudo modprobe vesafb 2>/dev/null || print_status "vesafb module: not available"
        
        # Try to create framebuffer device if it doesn't exist
        if [ ! -c "/dev/fb0" ]; then
            sudo mknod /dev/fb0 c 29 0 2>/dev/null || true
            sudo chmod 666 /dev/fb0 2>/dev/null || true
        fi
    fi
    
    # Alternative: Try to enable framebuffer through other methods
    if [ ! -c "/dev/fb0" ]; then
        print_status "Trying alternative framebuffer initialization..."
        
        # Check if we can find framebuffer in /sys
        if [ -d "/sys/class/graphics" ]; then
            for fb_sys in /sys/class/graphics/fb*; do
                if [ -d "$fb_sys" ]; then
                    fb_name=$(basename "$fb_sys")
                    
                    # Skip fbcon (console driver, not a framebuffer device)
                    if [ "$fb_name" = "fbcon" ]; then
                        print_status "Skipping fbcon (console driver, not a device)"
                        continue
                    fi
                    
                    # Only process actual framebuffer devices (fb0, fb1, etc.)
                    if echo "$fb_name" | grep -qE '^fb[0-9]+$'; then
                        fb_num=$(echo "$fb_name" | sed 's/fb//')
                        
                        if [ ! -c "/dev/$fb_name" ]; then
                            print_status "Creating framebuffer device /dev/$fb_name"
                            sudo mknod "/dev/$fb_name" c 29 "$fb_num" 2>/dev/null || true
                            sudo chmod 666 "/dev/$fb_name" 2>/dev/null || true
                        else
                            print_status "Framebuffer device /dev/$fb_name already exists"
                        fi
                    else
                        print_status "Skipping non-framebuffer entry: $fb_name"
                    fi
                fi
            done
        fi
        
        # Try to initialize framebuffer through sysfs
        if [ -f "/sys/class/graphics/fbcon/cursor_blink" ]; then
            echo 0 | sudo tee /sys/class/graphics/fbcon/cursor_blink >/dev/null 2>&1 || true
        fi
    fi
    
    # Wait a moment for devices to appear
    sleep 2
    
    # Check if framebuffer is now available
    if [ -c "/dev/fb0" ]; then
        print_success "Framebuffer device /dev/fb0 is now available"
        sudo chmod 666 /dev/fb0
        return 0
    else
        print_warning "Framebuffer device still not available"
        
        # Check if framebuffer support exists in kernel but device creation failed
        if [ -d "/sys/class/graphics" ]; then
            print_status "Graphics support exists in kernel - trying device creation..."
            
            # Try to manually create framebuffer devices
            for fb_sys in /sys/class/graphics/fb*; do
                if [ -d "$fb_sys" ]; then
                    fb_num=$(basename "$fb_sys" | sed 's/fb//')
                    if [ ! -c "/dev/fb$fb_num" ]; then
                        print_status "Creating /dev/fb$fb_num manually..."
                        sudo mknod "/dev/fb$fb_num" c 29 "$fb_num" 2>/dev/null || true
                        sudo chmod 666 "/dev/fb$fb_num" 2>/dev/null || true
                    fi
                fi
            done
            
            # Check again
            if [ -c "/dev/fb0" ]; then
                print_success "Framebuffer device created successfully"
                return 0
            fi
        fi
        
        print_warning "Framebuffer not available - this may be normal for this kernel/system"
        print_status "RECOMMENDED: Use modern KMS/DRM instead of legacy framebuffer:"
        echo "  1. Check KMS/DRM support: ls -la /dev/dri/*"
        echo "  2. Use KMS/DRM driver: SDL_VIDEODRIVER=kmsdrm"
        echo "  3. Test KMS/DRM: sudo ./setup.sh --test-kmsdrm"
        echo ""
        print_status "Alternative solutions if KMS/DRM unavailable:"
        echo "  1. Reboot system: sudo reboot"
        echo "  2. Use software rendering: SDL_VIDEODRIVER=software"
        echo "  3. Install X11 and use: SDL_VIDEODRIVER=x11"
        echo ""
        print_warning "Note: Framebuffer (fbcon) is legacy 1990s technology."
        print_warning "KMS/DRM is the modern standard with better performance."
        
        return 1
    fi
}

# Function to enable and test framebuffer functionality
test_framebuffer() {
    print_status "Testing framebuffer functionality..."
    
    # First, recommend modern KMS/DRM over legacy framebuffer
    print_warning "NOTE: Framebuffer is legacy technology. Consider KMS/DRM first:"
    echo "  - Test KMS/DRM: sudo ./setup.sh --test-kmsdrm"
    echo "  - Use KMS/DRM: SDL_VIDEODRIVER=kmsdrm"
    echo ""
    
    if [ ! -c "/dev/fb0" ]; then
        print_warning "Framebuffer /dev/fb0 not available - running diagnostics..."
        diagnose_framebuffer
        
        print_status "Attempting to enable framebuffer..."
        enable_framebuffer
        
        # Check again after fix attempt
        if [ ! -c "/dev/fb0" ]; then
            print_error "Framebuffer still not available after fix attempt"
            print_status "This likely requires a reboot for the graphics configuration to take effect"
            print_status "After reboot, try: sudo ./setup.sh --test-framebuffer"
            print_warning "RECOMMENDED: Use KMS/DRM instead: SDL_VIDEODRIVER=kmsdrm"
            return 1
        else
            print_success "Framebuffer enabled successfully"
        fi
    fi
    
    # Check framebuffer info
    if command -v fbset >/dev/null 2>&1; then
        print_status "Framebuffer information:"
        fbset -s 2>/dev/null | while IFS= read -r line; do
            print_status "  $line"
        done
    fi
    
    # Test framebuffer write permissions
    if [ -w "/dev/fb0" ]; then
        print_success "Framebuffer is writable"
        
        # Quick visual test (optional)
        print_status "Do you want to test framebuffer output with a quick flash? (y/n)"
        read -r test_fb
        if [[ "$test_fb" =~ ^[Yy]$ ]]; then
            print_status "Testing framebuffer output (you should see a brief flash)..."
            # Fill screen with white briefly then clear
            dd if=/dev/zero of=/dev/fb0 bs=1024 count=1 2>/dev/null || true
            sleep 0.5
            dd if=/dev/zero of=/dev/fb0 bs=1024 count=8192 2>/dev/null || true
            print_status "Framebuffer test completed"
        fi
    else
        print_warning "Framebuffer is not writable - may need permission fix"
        print_status "Trying to fix framebuffer permissions..."
        sudo chmod 666 /dev/fb0 2>/dev/null || true
        if [ -w "/dev/fb0" ]; then
            print_success "Fixed framebuffer permissions"
        else
            print_error "Could not fix framebuffer permissions"
        fi
    fi
}



# Function to configure AWS CLI using credentials from .env file
configure_aws_cli() {
    print_status "Configuring AWS CLI with credentials from .env file..."
    
    # Check if AWS CLI is installed
    if ! command_exists aws; then
        print_warning "AWS CLI not found. It should have been installed during package installation."
        return 1
    fi
    
    # Check if .env file exists
    if [ ! -f ".env" ]; then
        print_warning ".env file not found. AWS CLI configuration skipped."
        print_status "You can configure AWS CLI manually later using: aws configure"
        return 1
    fi
    
    # Source the .env file to get credentials
    set -a  # automatically export all variables
    source .env 2>/dev/null || {
        print_error "Failed to source .env file"
        return 1
    }
    set +a  # stop automatically exporting
    
    # Check if AWS credentials are set in .env
    if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$AWS_DEFAULT_REGION" ]; then
        print_warning "AWS credentials not found in .env file"
        print_status "Please edit .env file and set:"
        echo "  AWS_ACCESS_KEY_ID=your-aws-access-key-id"
        echo "  AWS_SECRET_ACCESS_KEY=your-aws-secret-access-key"
        echo "  AWS_DEFAULT_REGION=your-aws-region"
        return 1
    fi
    
    # Check if credentials are still placeholder values
    if [ "$AWS_ACCESS_KEY_ID" = "your-aws-access-key-id" ] || [ "$AWS_SECRET_ACCESS_KEY" = "your-aws-secret-access-key" ]; then
        print_warning "AWS credentials in .env file are still placeholder values"
        print_status "Please edit .env file with your actual AWS credentials"
        return 1
    fi
    
    # Export AWS environment variables for CLI
    export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
    export AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION"
    
    # Test AWS connection
    print_status "Testing AWS credentials..."
    if aws sts get-caller-identity >/dev/null 2>&1; then
        print_success "AWS CLI configured and authenticated successfully!"
        
        # Test S3 bucket access if ART_FRAME_S3_BUCKET is set
        if [ -n "$ART_FRAME_S3_BUCKET" ] && [ "$ART_FRAME_S3_BUCKET" != "your-bucket-name" ]; then
            print_status "Testing S3 bucket access: $ART_FRAME_S3_BUCKET"
            if aws s3api head-bucket --bucket "$ART_FRAME_S3_BUCKET" >/dev/null 2>&1; then
                print_success "S3 bucket '$ART_FRAME_S3_BUCKET' is accessible!"
            else
                print_warning "S3 bucket '$ART_FRAME_S3_BUCKET' is not accessible or doesn't exist"
                print_status "This may be normal if the bucket will be created later"
            fi
        fi
        
        # Show current AWS configuration
        print_status "AWS CLI Configuration:"
        aws configure list 2>/dev/null || true
        
        return 0
    else
        print_error "AWS credentials authentication failed"
        print_status "Please verify your credentials in .env file"
        return 1
    fi
}

# Function to build the project
build_project() {
    print_status "Building the project..."
    
    # Clean any previous builds
    go clean
    
    # Remove any existing executable
    rm -f art-frame
    
    print_status "Compiling Go project with CGO enabled..."
    
    # Set CGO environment
    export CGO_ENABLED=1
    
    # Build the project with verbose output
    if go build -v -o art-frame . 2>&1; then
        # Verify executable was actually created
        if [ -f "art-frame" ]; then
            # Check if executable has correct permissions
            if [ -x "art-frame" ]; then
                # Test that executable can be run (basic smoke test)
                print_status "Testing executable..."
                # Fix ownership and permissions for systemd compatibility
                print_status "Fixing executable permissions for systemd..."
                
                # Get the user who should own the files (prefer current user or SUDO_USER)
                local target_user="${SUDO_USER:-$(whoami)}"
                if [ "$target_user" = "root" ] || [ "$target_user" = "UNKNOWN" ]; then
                    target_user="root"
                fi
                
                # Set proper ownership
                chown "$target_user:$target_user" art-frame 2>/dev/null || true
                
                # Set executable permissions (755 = rwxr-xr-x)
                chmod 755 art-frame
                
                # Ensure directory permissions are correct
                chmod 755 . 2>/dev/null || true
                
                print_status "Permission fix applied:"
                print_status "  Owner: $(stat -c '%U:%G' art-frame 2>/dev/null || stat -f '%Su:%Sg' art-frame 2>/dev/null || echo 'unknown')"
                print_status "  Permissions: $(stat -c '%a' art-frame 2>/dev/null || stat -f '%Lp' art-frame 2>/dev/null || echo 'unknown')"
                
                if timeout 5 ./art-frame --version 2>/dev/null || timeout 5 ./art-frame --help 2>/dev/null || [ $? -eq 124 ]; then
                    print_success "Project built and tested successfully"
                    print_status "Executable location: $(pwd)/art-frame"
                    print_status "Executable size: $(ls -lh art-frame | awk '{print $5}')"
                    return 0
                else
                    print_warning "Executable built but failed basic test"
                    print_status "This may be normal if the app requires specific runtime environment"
                    return 0
                fi
            else
                print_error "Executable created but not executable"
                print_status "Fixing executable permissions..."
                
                # Get the user who should own the files
                local target_user="${SUDO_USER:-$(whoami)}"
                if [ "$target_user" = "root" ] || [ "$target_user" = "UNKNOWN" ]; then
                    target_user="root"
                fi
                
                # Set proper ownership and permissions
                chown "$target_user:$target_user" art-frame 2>/dev/null || true
                chmod 755 art-frame
                chmod 755 . 2>/dev/null || true
                
                print_success "Fixed executable permissions"
                print_status "  Owner: $(stat -c '%U:%G' art-frame 2>/dev/null || stat -f '%Su:%Sg' art-frame 2>/dev/null || echo 'unknown')"
                print_status "  Permissions: $(stat -c '%a' art-frame 2>/dev/null || stat -f '%Lp' art-frame 2>/dev/null || echo 'unknown')"
                return 0
            fi
        else
            print_error "Build command succeeded but no executable was created"
            print_status "This may indicate a Go module or output path issue"
            return 1
        fi
    else
        print_error "Go build command failed"
        print_status "Build error details should be shown above"
        return 1
    fi
}

# Function to check if systemd service exists
service_exists() {
    systemctl list-unit-files | grep -q "art-frame.service"
}

# Function to manage existing systemd service
manage_existing_service() {
    print_status "Art Frame systemd service is already installed."
    echo
    print_status "What would you like to do?"
    echo "  1) Reinstall/Update the service"
    echo "  2) Remove the service"
    echo "  3) Keep existing service"
    echo -n "Choose an option (1-3): "
    read -r choice
    
    case "$choice" in
        1)
            print_status "Stopping and removing existing service..."
            sudo systemctl stop art-frame 2>/dev/null || true
            sudo systemctl disable art-frame 2>/dev/null || true
            sudo rm -f /etc/systemd/system/art-frame.service
            sudo systemctl daemon-reload
            print_success "Existing service removed. Installing new service..."
            return 0  # Proceed with installation
            ;;
        2)
            print_status "Removing systemd service..."
            sudo systemctl stop art-frame 2>/dev/null || true
            sudo systemctl disable art-frame 2>/dev/null || true
            sudo rm -f /etc/systemd/system/art-frame.service
            sudo systemctl daemon-reload
            print_success "Systemd service removed successfully"
            return 1  # Don't install
            ;;
        3)
            print_status "Keeping existing service unchanged"
            return 1  # Don't install
            ;;
        *)
            print_warning "Invalid choice. Keeping existing service unchanged"
            return 1  # Don't install
            ;;
    esac
}

# Function to verify executable before service creation
verify_executable() {
    local executable_path="$1"
    
    print_status "Verifying executable: $executable_path"
    
    if [ ! -f "$executable_path" ]; then
        print_error "Executable not found: $executable_path"
        return 1
    fi
    
    if [ ! -x "$executable_path" ]; then
        print_error "File exists but is not executable: $executable_path"
        print_status "Attempting to fix permissions..."
        chmod +x "$executable_path"
        if [ ! -x "$executable_path" ]; then
            print_error "Failed to make executable"
            return 1
        fi
        print_success "Fixed executable permissions"
    fi
    
    # Get file info
    local file_size=$(ls -lh "$executable_path" | awk '{print $5}')
    local file_perms=$(ls -l "$executable_path" | awk '{print $1}')
    
    print_status "Executable verification:"
    print_status "  Path: $executable_path"
    print_status "  Size: $file_size"
    print_status "  Permissions: $file_perms"
    
    # Basic executable test
    print_status "Testing executable can run..."
    if timeout 3 "$executable_path" --version 2>/dev/null || timeout 3 "$executable_path" --help 2>/dev/null || [ $? -eq 124 ]; then
        print_success "Executable test passed"
    else
        print_warning "Executable test failed (may require runtime environment)"
        print_status "Continuing anyway - this may be normal for this application"
    fi
    
    return 0
}

# Function to create and install systemd service
create_systemd_service() {
    print_status "Creating and installing systemd service..."
    
    local service_file="art-frame.service"
    local current_dir=$(pwd)
    print_status "Current directory: $current_dir"
    print_status "Current directory files: $(ls -la $current_dir)"
    local current_user=$(whoami)
    local executable_path="$current_dir/art-frame"
    
    # First, verify the executable exists and works
    if ! verify_executable "$executable_path"; then
        print_error "Cannot create systemd service - executable verification failed"
        print_status "Build the project first with: go build -o art-frame ."
        return 1
    fi
    
    # Additional debugging for systemd path issues
    print_status "Systemd Service Debug Information:"
    print_status "  Working Directory: $current_dir"
    print_status "  Executable Path: $executable_path"
    print_status "  Current User: $current_user"
    print_status "  Executable exists: $([ -f "$executable_path" ] && echo "YES" || echo "NO")"
    print_status "  Executable readable: $([ -r "$executable_path" ] && echo "YES" || echo "NO")"
    print_status "  Executable executable: $([ -x "$executable_path" ] && echo "YES" || echo "NO")"
    print_status "  Full path verification: $(ls -la "$executable_path" 2>/dev/null || echo "FAILED")"
    
    # Test the exact command systemd will run
    print_status "Testing exact systemd command..."
    if timeout 5 "$executable_path" --version 2>/dev/null || timeout 5 "$executable_path" --help 2>/dev/null || [ $? -eq 124 ]; then
        print_success "Direct executable path test passed"
    else
        print_warning "Direct executable path test failed - systemd may have issues"
    fi
    
    # Check if the wrapper script exists and is executable
    if [ ! -f "$current_dir/check-updates-wrapper.sh" ]; then
        print_error "Service wrapper script not found: $current_dir/check-updates-wrapper.sh"
        print_status "Please ensure check-updates-wrapper.sh exists in the project root directory"
        exit 1
    fi
    
    if [ ! -x "$current_dir/check-updates-wrapper.sh" ]; then
        print_status "Making wrapper script executable..."
        chmod +x "$current_dir/check-updates-wrapper.sh"
    fi
    
    print_success "Using existing service wrapper script: $current_dir/check-updates-wrapper.sh"

    # Create the service file
    cat > "$service_file" << EOF
[Unit]
Description=Art Frame Digital Picture Frame
After=graphical-session.target network.target
Wants=graphical-session.target

[Service]
Type=simple
User=$current_user
Group=$current_user
WorkingDirectory=$current_dir
ExecStartPre=$current_dir/check-updates-wrapper.sh
ExecStart=$executable_path
Restart=always
RestartSec=10
RestartPreventExitStatus=0
KillMode=mixed
TimeoutStartSec=300
TimeoutStopSec=300
TimeoutAbortSec=300
Environment=DISPLAY=${DETECTED_DISPLAY:-:0}
Environment=SDL_VIDEODRIVER=${DETECTED_SDL_DRIVER:-kmsdrm}
Environment=HOME=$current_dir
EnvironmentFile=$current_dir/.env
StandardOutput=journal
StandardError=journal
SyslogIdentifier=art-frame

# Relaxed security settings for /root access
NoNewPrivileges=false
PrivateTmp=false
ProtectSystem=false
ProtectHome=false
ReadWritePaths=$current_dir

[Install]
WantedBy=graphical-session.target multi-user.target
EOF
    
    print_success "Systemd service file created: $service_file"
    
    # Show the service file contents for debugging
    print_status "Service file contents for debugging:"
    cat "$service_file" | while IFS= read -r line; do
        print_status "  $line"
    done
    
    # Verify the service file before installing
    print_status "Service file verification:"
    local wrapper_path="$current_dir/check-updates-wrapper.sh"
    if grep -q "ExecStartPre=$wrapper_path" "$service_file" && grep -q "ExecStart=$executable_path" "$service_file"; then
        print_success "ExecStartPre and ExecStart paths correctly set in service file"
    else
        print_error "ExecStartPre or ExecStart path mismatch in service file!"
        print_status "Expected: ExecStartPre=$wrapper_path"
        print_status "Expected: ExecStart=$executable_path"
        print_status "Found ExecStartPre: $(grep ExecStartPre "$service_file" || echo "NO ExecStartPre FOUND")"
        print_status "Found ExecStart: $(grep ExecStart "$service_file" || echo "NO ExecStart FOUND")"
    fi
    
    # Install the service
    print_status "Installing systemd service..."
    sudo cp "$service_file" /etc/systemd/system/
    
    # Verify the installed service file
    print_status "Verifying installed service file..."
    if [ -f "/etc/systemd/system/art-frame.service" ]; then
        print_status "Installed service file contents:"
        cat /etc/systemd/system/art-frame.service | while IFS= read -r line; do
            print_status "  $line"
        done
        
        # Check if the ExecStartPre and ExecStart paths match what we expect
        installed_exec_start_pre=$(grep "^ExecStartPre=" /etc/systemd/system/art-frame.service | cut -d'=' -f2)
        installed_exec_start=$(grep "^ExecStart=" /etc/systemd/system/art-frame.service | cut -d'=' -f2)
        local wrapper_path="$current_dir/check-updates-wrapper.sh"
        if [ "$installed_exec_start_pre" = "$wrapper_path" ] && [ "$installed_exec_start" = "$executable_path" ]; then
            print_success "Installed service ExecStartPre and ExecStart paths are correct"
            print_status "  ExecStartPre: $installed_exec_start_pre"
            print_status "  ExecStart: $installed_exec_start"
        else
            print_error "Installed service ExecStartPre or ExecStart path mismatch!"
            print_status "  Expected ExecStartPre: $wrapper_path"
            print_status "  Expected ExecStart: $executable_path"
            print_status "  Found ExecStartPre: $installed_exec_start_pre"
            print_status "  Found ExecStart: $installed_exec_start"
        fi
    else
        print_error "Service file not found at /etc/systemd/system/art-frame.service"
    fi
    
    # Reload systemd daemon
    print_status "Reloading systemd daemon..."
    sudo systemctl daemon-reload
    
    # Enable the service for startup
    print_status "Enabling art-frame service for startup..."
    sudo systemctl enable art-frame
    
    # Final verification before starting service
    print_status "Final pre-start verification..."
    installed_exec_start_pre=$(grep "^ExecStartPre=" /etc/systemd/system/art-frame.service | cut -d'=' -f2)
    installed_exec_start=$(grep "^ExecStart=" /etc/systemd/system/art-frame.service | cut -d'=' -f2)
    local wrapper_path="$current_dir/check-updates-wrapper.sh"
    
    if [ -f "$installed_exec_start_pre" ] && [ -f "$installed_exec_start" ]; then
        print_success "Wrapper script and executable exist at systemd paths"
        print_status "  ExecStartPre (wrapper): $installed_exec_start_pre"
        print_status "  ExecStart (executable): $installed_exec_start"
        print_status "  Wrapper script info: $(ls -la "$installed_exec_start_pre")"
        print_status "  Executable info: $(ls -la "$installed_exec_start")"
        
        # Test if systemd can actually execute both
        if sudo -u root test -x "$installed_exec_start_pre"; then
            print_success "Systemd can access and execute the wrapper script"
        else
            print_error "Systemd cannot access or execute the wrapper script!"
        fi
        
        if sudo -u root test -x "$installed_exec_start"; then
            print_success "Systemd can access and execute the main executable"
        else
            print_error "Systemd cannot access or execute the main executable!"
        fi
        
        # Create a wrapper script as backup solution
        print_status "Creating systemd wrapper script as backup..."
        cat > "$current_dir/art-frame-wrapper.sh" << EOF
#!/bin/bash
# Systemd wrapper script for art-frame
cd "$current_dir"
export HOME="$current_dir"
export DISPLAY="${DETECTED_DISPLAY:-:0}"
export SDL_VIDEODRIVER="${DETECTED_SDL_DRIVER:-kmsdrm}"
exec "$executable_path" "\$@"
EOF
        
        chmod +x "$current_dir/art-frame-wrapper.sh"
        chown root:root "$current_dir/art-frame-wrapper.sh" 2>/dev/null || true
        
        print_status "Wrapper script created: $current_dir/art-frame-wrapper.sh"
        
        # Test the wrapper
        if timeout 3 "$current_dir/art-frame-wrapper.sh" --version 2>/dev/null || timeout 3 "$current_dir/art-frame-wrapper.sh" --help 2>/dev/null || [ $? -eq 124 ]; then
            print_success "Wrapper script test passed"
        else
            print_warning "Wrapper script test failed"
        fi
    else
        if [ ! -f "$installed_exec_start_pre" ]; then
            print_error "CRITICAL: Wrapper script not found at systemd path: $installed_exec_start_pre"
        fi
        if [ ! -f "$installed_exec_start" ]; then
            print_error "CRITICAL: Executable not found at systemd path: $installed_exec_start"
        fi
        print_status "This will cause systemd to fail!"
        return 1
    fi
    
    # Start the service immediately
    print_status "Starting art-frame service..."
    sudo systemctl start art-frame
    
    # Check service status
    if sudo systemctl is-active --quiet art-frame; then
        print_success "Art Frame service is running successfully!"
        
        # Apply preventive fix for common HOME directory permission issue
        print_status "Applying preventive fix for HOME directory permission issues..."
        if sudo sed -i '/Environment=HOME=/d' /etc/systemd/system/art-frame.service 2>/dev/null; then
            sudo systemctl daemon-reload
            sudo systemctl restart art-frame
            print_success "Applied HOME directory permission fix"
        else
            print_warning "Could not apply HOME directory fix - service may still work"
        fi
        
        # Show current service status
        echo
        print_status "Current service status:"
        sudo systemctl status art-frame --no-pager -l
    else
        print_warning "Service may not be running. Diagnosing..."
        
        # Show detailed status first
        print_status "Service status check:"
        sudo systemctl status art-frame --no-pager -l || true
        
        # Show recent logs
        print_status "Recent service logs:"
        sudo journalctl -u art-frame --no-pager -l -n 10 || true
        
        print_status "Attempting to start the service..."
        sudo systemctl start art-frame
        sleep 3
        
        if sudo systemctl is-active --quiet art-frame; then
            print_success "Service started successfully!"
        else
            print_error "Service failed to start. Detailed diagnostics:"
            
            # More detailed diagnostics
            print_status "Service status after start attempt:"
            sudo systemctl status art-frame --no-pager -l || true
            
            print_status "Latest service logs:"
            sudo journalctl -u art-frame --no-pager -l -n 20 || true
            
            print_status "File system check:"
            print_status "  Executable still exists: $([ -f "$executable_path" ] && echo "YES" || echo "NO")"
            print_status "  Executable permissions: $(ls -la "$executable_path" 2>/dev/null || echo "MISSING")"
            
            print_status "Manual test of executable:"
            if sudo "$executable_path" --version 2>/dev/null || sudo "$executable_path" --help 2>/dev/null; then
                print_status "  Manual execution: SUCCESS"
            else
                print_status "  Manual execution: FAILED"
            fi
            
            # Check for library dependencies
            print_status "Checking shared library dependencies:"
            if command -v ldd >/dev/null 2>&1; then
                ldd "$executable_path" 2>/dev/null | head -10 | while IFS= read -r line; do
                    print_status "  $line"
                done
            else
                print_status "  ldd not available for dependency check"
            fi
            
                         # Test with systemd-run for exact systemd environment
             print_status "Testing with systemd-run (simulates systemd environment):"
             if timeout 5 systemd-run --wait --uid=root --gid=root "$executable_path" --version 2>/dev/null; then
                 print_status "  systemd-run test: SUCCESS"
             else
                 print_status "  systemd-run test: FAILED - this confirms systemd environment issue"
             fi
             
             # Provide solution for systemd access issues
             print_status "SOLUTION: Use wrapper script approach:"
             echo
             print_status "1. Edit the systemd service to use wrapper script:"
             echo "   sudo nano /etc/systemd/system/art-frame.service"
             echo
             print_status "2. Change the ExecStart line to:"
             echo "   ExecStart=$current_dir/art-frame-wrapper.sh"
             echo
             print_status "3. Remove or disable security restrictions:"
             echo "   # Comment out or change these lines:"
             echo "   # NoNewPrivileges=false"
             echo "   # ProtectSystem=false"
             echo "   # ProtectHome=false"
             echo
             print_status "4. Reload and restart:"
             echo "   sudo systemctl daemon-reload"
             echo "   sudo systemctl restart art-frame"
             echo "   sudo systemctl status art-frame"
        fi
    fi
    
    print_success "Systemd service installed and configured"
    print_status "Service management commands:"
    echo "  - Check status: sudo systemctl status art-frame"
    echo "  - Stop service: sudo systemctl stop art-frame"
    echo "  - Start service: sudo systemctl start art-frame"
    echo "  - Restart service: sudo systemctl restart art-frame"
    echo "  - View logs: sudo journalctl -u art-frame -f"
    echo "  - Disable startup: sudo systemctl disable art-frame"
}

# Function to provide recovery options when build fails
provide_recovery_options() {
    print_error "Build failed - providing recovery options..."
    echo
    print_status "Recovery Options:"
    echo
    print_status "1. Manual Build:"
    echo "   cd $(pwd)"
    echo "   export CGO_ENABLED=1"
    echo "   go clean"
    echo "   go build -v -o art-frame ."
    echo "   # Fix permissions for systemd:"
    echo "   sudo chown root:root art-frame"
    echo "   sudo chmod 755 art-frame"
    echo "   sudo chmod 755 ."
    echo
    print_status "2. Debug Build Issues:"
    echo "   pkg-config --libs libavformat libavcodec libavutil"
    echo "   go env"
    echo "   go list -m all"
    echo
    print_status "3. Install Missing Dependencies:"
    echo "   sudo apt-get install libavformat-dev libavcodec-dev libavutil-dev libswscale-dev"
    echo "   # OR for other distros:"
    echo "   sudo dnf install ffmpeg-devel"
    echo "   sudo pacman -S ffmpeg"
    echo
    print_status "4. Environment Variables (if needed):"
    echo "   export CGO_CFLAGS=\"-I/usr/include/ffmpeg\""
    echo "   export CGO_LDFLAGS=\"-L/usr/lib -lavformat -lavcodec -lavutil\""
    echo "   go build -o art-frame ."
    echo "   # Fix permissions:"
    echo "   sudo chown root:root art-frame && sudo chmod 755 art-frame"
    echo
    print_status "5. Continue Setup Without Systemd Service:"
    echo "   - Fix build issues manually"
    echo "   - Run: ./art-frame to test"
    echo "   - Install service later: sudo systemctl --user enable art-frame.service"
    echo
    print_status "6. Display Troubleshooting (if app runs but no display):"
    echo "   # Test different SDL drivers (in order of preference):"
    echo "   # 1. KMS/DRM (RECOMMENDED - modern, hardware-accelerated):"
    echo "   export SDL_VIDEODRIVER=kmsdrm && ./art-frame"
    echo "   # 2. X11 (if X server running):"
    echo "   export SDL_VIDEODRIVER=x11 && ./art-frame"
    echo "   # 3. Software rendering (works everywhere):"
    echo "   export SDL_VIDEODRIVER=software && ./art-frame"
    echo "   # 4. Framebuffer (LEGACY - avoid if possible):"
    echo "   export SDL_VIDEODRIVER=fbcon && ./art-frame"
    echo "   # Check graphics capabilities:"
    echo "   ls -la /dev/dri/*"
    echo "   lsmod | grep drm"
    echo "   echo \$DISPLAY"
    echo "   ps aux | grep X"
    echo
    print_status "7. Raspberry Pi Specific Troubleshooting:"
    echo "   # Check Pi model and GPU memory:"
    echo "   cat /proc/device-tree/model"
    echo "   vcgencmd get_mem gpu"
    echo "   vcgencmd get_throttled  # Check for under-voltage"
    echo "   # Check KMS/DRM support (PREFERRED - modern graphics):"
    echo "   ls -la /dev/dri/*"
    echo "   lsmod | grep -E '(drm|vc4)'"
    echo "   ls -la /sys/class/drm/"
    echo "   sudo ./setup.sh --test-kmsdrm"
    echo "   # Test KMS/DRM driver (RECOMMENDED):"
    echo "   export SDL_VIDEODRIVER=kmsdrm && ./art-frame"
    echo "   # If KMS/DRM fails, check framebuffer (LEGACY fallback):"
    echo "   ls -la /dev/fb*"
    echo "   sudo ./setup.sh --diagnose-framebuffer"
    echo "   export SDL_VIDEODRIVER=fbcon && ./art-frame"
    echo "   # NOTE: fbcon is 1990s technology - prefer kmsdrm when possible"
    echo "   # Fix rainbow flashes (power/graphics issues):"
    echo "   sudo ./setup.sh --fix-rainbow"
    echo "   # Configure graphics mode:"
    echo "   sudo raspi-config  # Advanced Options > GL Driver"
    echo "   # For KMS/DRM (modern): Choose 'GL (Full KMS)'"
    echo "   # For Legacy: Choose 'Legacy'"
    echo "   # Edit /boot/config.txt for specific needs:"
    echo "   echo 'gpu_mem=64' | sudo tee -a /boot/config.txt"
    echo "   echo 'dtoverlay=vc4-kms-v3d' | sudo tee -a /boot/config.txt  # For KMS"
    echo "   sudo reboot"
    echo
}

# Function to handle build failure scenarios
handle_build_failure() {
    local build_exit_code=$1
    
    print_error "Build process failed with exit code: $build_exit_code"
    
    # Provide specific guidance based on common failure modes
    case $build_exit_code in
        1)
            print_status "This usually indicates compilation errors"
            print_status "Check the build output above for specific error messages"
            ;;
        2)
            print_status "This may indicate missing dependencies or pkg-config issues"
            ;;
        *)
            print_status "Unexpected build failure"
            ;;
    esac
    
    provide_recovery_options
    
    # Ask user what they want to do
    echo
    print_status "What would you like to do?"
    echo "  1) Continue setup without building (you can build manually later)"
    echo "  2) Exit setup to fix issues manually"
    echo "  3) Try alternative build method"
    echo -n "Choose an option (1-3): "
    
    read -r choice
    case "$choice" in
        1)
            print_warning "Continuing setup without executable - systemd service will be skipped"
            return 0  # Continue but skip service creation
            ;;
        2)
            print_status "Exiting setup. Use the recovery options above to fix issues."
            exit 1
            ;;
        3)
            print_status "Trying alternative build method..."
            return 2  # Try alternative build
            ;;
        *)
            print_warning "Invalid choice, continuing setup without building"
            return 0
            ;;
    esac
}

# Function to attempt alternative build methods
try_alternative_build() {
    print_status "Attempting alternative build methods..."
    
    # Method 1: Disable CGO and try pure Go build (if possible)
    print_status "Trying with CGO disabled..."
    export CGO_ENABLED=0
    if go build -o art-frame-nocgo . 2>/dev/null; then
        print_warning "Built with CGO disabled (may lack some features)"
        mv art-frame-nocgo art-frame
        
        # Apply the same permission fixes
        local target_user="${SUDO_USER:-$(whoami)}"
        if [ "$target_user" = "root" ] || [ "$target_user" = "UNKNOWN" ]; then
            target_user="root"
        fi
        chown "$target_user:$target_user" art-frame 2>/dev/null || true
        chmod 755 art-frame
        chmod 755 . 2>/dev/null || true
        
        print_status "Alternative build permissions fixed"
        return 0
    fi
    
    # Method 2: Try with minimal CGO flags
    print_status "Trying with minimal CGO flags..."
    export CGO_ENABLED=1
    export CGO_CFLAGS=""
    export CGO_LDFLAGS=""
    if go build -o art-frame . 2>/dev/null; then
        # Apply permission fixes
        local target_user="${SUDO_USER:-$(whoami)}"
        if [ "$target_user" = "root" ] || [ "$target_user" = "UNKNOWN" ]; then
            target_user="root"
        fi
        chown "$target_user:$target_user" art-frame 2>/dev/null || true
        chmod 755 art-frame
        chmod 755 . 2>/dev/null || true
        
        print_success "Alternative build method successful"
        return 0
    fi
    
    # Method 3: Try building in container-friendly mode
    print_status "Trying container-friendly build..."
    export GOOS=linux
    export GOARCH=amd64
    if go build -a -installsuffix cgo -o art-frame . 2>/dev/null; then
        # Apply permission fixes
        local target_user="${SUDO_USER:-$(whoami)}"
        if [ "$target_user" = "root" ] || [ "$target_user" = "UNKNOWN" ]; then
            target_user="root"
        fi
        chown "$target_user:$target_user" art-frame 2>/dev/null || true
        chmod 755 art-frame
        chmod 755 . 2>/dev/null || true
        
        print_success "Container-friendly build successful"
        return 0
    fi
    
    print_error "All alternative build methods failed"
    return 1
}

# Function to provide manual systemd service instructions
provide_manual_service_instructions() {
    print_status "Manual systemd service installation instructions:"
    echo
    print_status "1. First ensure executable exists:"
    echo "   ls -la $(pwd)/art-frame"
    echo
    print_status "2. Create service file manually:"
    echo "   sudo nano /etc/systemd/system/art-frame.service"
    echo
    print_status "3. Use this service file content:"
    cat << EOF
[Unit]
Description=Art Frame Digital Picture Frame
After=graphical-session.target network.target
Wants=graphical-session.target

[Service]
Type=simple
User=$(whoami)
Group=$(whoami)
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/art-frame
Restart=always
RestartSec=10
Environment=DISPLAY=:0
Environment=SDL_VIDEODRIVER=kmsdrm
Environment=HOME=$(pwd)
EnvironmentFile=$(pwd)/.env
StandardOutput=journal
StandardError=journal

# Relaxed security for /root access
NoNewPrivileges=false
ProtectSystem=false
ProtectHome=false

[Install]
WantedBy=graphical-session.target multi-user.target
EOF
    echo
    print_status "4. Enable and start service:"
    echo "   sudo systemctl daemon-reload"
    echo "   sudo systemctl enable art-frame"
    echo "   sudo systemctl start art-frame"
    echo "   sudo systemctl status art-frame"
}

# Main setup function
main() {
    # Initialize flags
    SKIP_BUILD=${SKIP_BUILD:-false}
    SYSTEMD_ONLY=${SYSTEMD_ONLY:-false}
    
    print_status "Starting Art Frame setup for Linux..."
    
    # Handle root user and file permissions
    if [ "$EUID" -eq 0 ]; then
        print_warning "Running as root. This is needed for package installation but may cause file permission issues."
        
        # Try to determine the actual user who should own the files
        actual_user=$(get_actual_user)
        if [ $? -eq 0 ] && [ -n "$actual_user" ] && is_valid_user "$actual_user"; then
            if [ -n "$SETUP_USER" ]; then
                print_status "Using user specified in SETUP_USER: $actual_user"
            elif [ -n "$SUDO_USER" ]; then
                print_status "Auto-detected user from sudo: $actual_user"
            else
                print_status "Auto-detected user from system: $actual_user"
            fi
            fix_file_permissions "$actual_user"
        else
            print_warning "Could not determine a valid target user for file ownership - continuing without permission fix"
            print_warning "Manual permission fix may be required after setup:"
            print_warning "  sudo chown -R \$USER:\$USER ."
            print_warning "Or run with explicit user: SETUP_USER=\"username\" sudo ./setup.sh"
        fi
    else
        # Not running as root, fix permissions anyway to ensure proper access
        print_status "Ensuring proper file permissions..."
        fix_file_permissions "$(whoami)"
    fi
    
    # Skip setup steps if in systemd-only mode
    if [ "$SYSTEMD_ONLY" != true ]; then
        # Install system packages
        install_packages
        
        # Verify FFmpeg pkg-config setup
        verify_ffmpeg_pkgconfig
        
        # Install Go 1.23.1
        install_go
        
        # Setup Go environment
        setup_go_env
        
        # Install Go dependencies
        install_go_deps
        
        # Test CGO and FFmpeg compilation
        test_cgo_ffmpeg
        
        # Setup display environment
        setup_display_environment
        
        # Test display configuration
        test_display_config
        
        # Test graphics functionality (prefer KMS/DRM over framebuffer)
        if [ -f "/proc/device-tree/model" ] && grep -qi "raspberry pi" /proc/device-tree/model; then
            print_status "Raspberry Pi detected - testing graphics capabilities..."
            
            # Test KMS/DRM first (modern, preferred)
            if [ -d "/dev/dri" ] && ls /dev/dri/card* >/dev/null 2>&1; then
                print_success "KMS/DRM available - testing..."
                test_kms_drm_support
                print_warning "RECOMMENDED: Use SDL_VIDEODRIVER=kmsdrm for best performance"
            else
                print_warning "KMS/DRM not available, testing legacy framebuffer..."
                test_framebuffer
            fi
        fi
        
        
        # Configure AWS CLI with credentials from .env file
        configure_aws_cli
    fi
    
    # Build the project with comprehensive error handling (unless skipped)
    if [ "$SKIP_BUILD" = true ]; then
        print_status "Skipping build step as requested"
        BUILD_SUCCESS=true
    else
        print_status "Starting build process..."
        if build_project; then
            print_success "Build completed successfully"
            BUILD_SUCCESS=true
        else
            print_error "Initial build failed"
            BUILD_SUCCESS=false
            
            # Handle build failure with recovery options
            handle_build_failure $?
            recovery_choice=$?
            
            case $recovery_choice in
                0)
                    # Continue without building
                    BUILD_SUCCESS=false
                    ;;
                2)
                    # Try alternative build methods
                    if try_alternative_build; then
                        print_success "Alternative build method succeeded"
                        BUILD_SUCCESS=true
                    else
                        print_error "All build methods failed"
                        BUILD_SUCCESS=false
                    fi
                    ;;
                *)
                    # Exit or continue without building
                    BUILD_SUCCESS=false
                    ;;
            esac
        fi
    fi
    
    # Handle systemd service installation
    echo
    if [ "$SYSTEMD_ONLY" = true ]; then
        print_status "Systemd-only mode - skipping full setup and proceeding directly to service installation"
        BUILD_SUCCESS=true
    fi
    
    if [ "$BUILD_SUCCESS" = true ]; then
        print_status "Proceeding with systemd service setup"
        
        if service_exists; then
            if manage_existing_service; then
                if create_systemd_service; then
                    print_success "Setup completed successfully!"
                    print_status "Art Frame is now running as a system service and will:"
                    echo "  - Start automatically on boot"
                    echo "  - Restart automatically if it crashes"
                    echo "  - Log to system journal"
                    if [ "$ENABLE_AUTO_UPDATE" = true ]; then
                        echo "  - Check for updates automatically on startup"
                    fi
                    echo
                    print_status "Next steps:"
                    if [ "$ENABLE_AUTO_UPDATE" = true ]; then
                        echo "  1. Configure AWS credentials in .env file: nano .env"
                        echo "     - Set ART_FRAME_S3_BUCKET to your S3 bucket name"
                        echo "     - Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
                        echo "  2. Upload your codebase to S3: ./upload-to-s3.sh your-bucket-name"
                        echo "  3. Restart the service: sudo systemctl restart art-frame"
                        echo "  4. View logs: sudo journalctl -u art-frame -f"
                        print_status "Auto-update is now enabled! The service will check for updates on startup."
                    else
                        echo "  1. Edit .env file with your specific configuration: nano .env"
                        echo "  2. Restart the service after editing .env: sudo systemctl restart art-frame"
                        echo "  3. View logs: sudo journalctl -u art-frame -f"
                    fi
                else
                    print_warning "Systemd service creation failed"
                    provide_manual_service_instructions
                fi
            else
                print_success "Setup completed successfully!"
                print_status "Next steps:"
                echo "  1. Edit .env file with your specific configuration: nano .env"
                echo "  2. Source your shell configuration: source ~/.bashrc"
                echo "  3. Run the application: ./art-frame"
            fi
        else
            if [ "$SYSTEMD_ONLY" = true ]; then
                # In systemd-only mode, create service without asking
                if create_systemd_service; then
                    print_success "Systemd service installed successfully!"
                    print_status "Art Frame is now running as a system service and will:"
                    echo "  - Start automatically on boot"
                    echo "  - Restart automatically if it crashes"
                    echo "  - Log to system journal"
                    if [ "$ENABLE_AUTO_UPDATE" = true ]; then
                        echo "  - Check for updates automatically on startup"
                    fi
                    echo
                    print_status "Next steps:"
                    echo "  1. Edit .env file with your specific configuration: nano .env"
                    echo "  2. Restart the service after editing .env: sudo systemctl restart art-frame"
                    echo "  3. View logs: sudo journalctl -u art-frame -f"
                else
                    print_error "Systemd service installation failed"
                    exit 1
                fi
            else
                print_status "Do you want to install and configure the systemd service?"
                print_status "This will make Art Frame start automatically on boot and restart on crash."
                echo -n "Install systemd service? (y/n): "
                read -r install_service
                
                if [[ "$install_service" =~ ^[Yy]$ ]]; then
                    if create_systemd_service; then
                        print_success "Setup completed successfully!"
                        print_status "Art Frame is now running as a system service and will:"
                        echo "  - Start automatically on boot"
                        echo "  - Restart automatically if it crashes"
                        echo "  - Log to system journal"
                        echo
                        print_status "Next steps:"
                        echo "  1. Edit .env file with your specific configuration: nano .env"
                        echo "  2. Restart the service after editing .env: sudo systemctl restart art-frame"
                        echo "  3. View logs: sudo journalctl -u art-frame -f"
                    else
                        print_warning "Systemd service creation failed"
                        provide_manual_service_instructions
                    fi
                fi
            fi
        fi
    else
        print_warning "Build failed - skipping systemd service installation"
        print_status "Setup completed with warnings!"
        echo
        print_status "Issues encountered:"
        echo "  - Executable build failed"
        echo "  - Systemd service not installed"
        echo
        print_status "Next steps:"
        echo "  1. Fix build issues manually (see recovery options above)"
        echo "  2. Test build with: go build -o art-frame ."
        echo "  3. Once built, run: ./art-frame"
        echo "  4. Install systemd service later: sudo ./setup.sh"
        echo
        provide_recovery_options
    fi
    
    print_warning "Note: You may need to restart your terminal or run 'source ~/.bashrc' for Go to be available in your PATH"
    
    # Check if reboot is needed for Raspberry Pi graphics changes
    if [ -f "/proc/device-tree/model" ] && grep -qi "raspberry pi" /proc/device-tree/model; then
        if [ -f "/boot/config.txt.backup."* ] 2>/dev/null; then
            echo
            print_warning "IMPORTANT: Raspberry Pi graphics configuration was updated!"
            print_warning "A reboot is required for graphics changes to take effect."
            print_status "After reboot, check if the service is working:"
            echo "  sudo systemctl status art-frame"
            echo "  sudo journalctl -u art-frame -f"
            echo
            print_status "Do you want to reboot now? (y/n)"
            read -r reboot_choice
            if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
                print_status "Rebooting in 5 seconds... (Ctrl+C to cancel)"
                sleep 5
                sudo reboot
            else
                print_warning "Remember to reboot manually: sudo reboot"
            fi
        fi
    fi
}



# Process command line arguments
SKIP_BUILD=false
SYSTEMD_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        "--skip-build")
            SKIP_BUILD=true
            shift
            ;;
        "--systemd-only")
            SYSTEMD_ONLY=true
            shift
            ;;
        "--test-display")
            print_status "Testing display configuration only..."
            setup_display_environment
            test_display_config
            if [ -f "/proc/device-tree/model" ] && grep -qi "raspberry pi" /proc/device-tree/model; then
                test_framebuffer
            fi
            exit 0
            ;;
        "--test-framebuffer")
            print_status "Testing framebuffer only..."
            test_framebuffer
            exit 0
            ;;
        "--fix-rainbow")
            print_status "Fixing Raspberry Pi rainbow flash issues..."
            fix_raspberry_pi_display_issues
            print_warning "Reboot required for changes to take effect: sudo reboot"
            exit 0
            ;;
        "--enable-framebuffer")
            print_status "Enabling framebuffer support..."
            enable_framebuffer
            print_warning "Reboot may be required for changes to take effect: sudo reboot"
            exit 0
            ;;
        "--diagnose-framebuffer")
            print_status "Diagnosing framebuffer status..."
            diagnose_framebuffer
            exit 0
            ;;
        "--test-kmsdrm")
            print_status "Testing KMS/DRM support..."
            test_kms_drm_support
            exit 0
            ;;
        "--help"|"-h")
            echo "Art Frame Setup Script"
            echo "Usage: $0 [option]"
            echo ""
            echo "Options:"
            echo "  --test-display         Test display configuration only"
            echo "  --test-kmsdrm          Test KMS/DRM support (recommended)"
            echo "  --test-framebuffer     Test framebuffer functionality (legacy)"
            echo "  --enable-framebuffer   Enable framebuffer support"
            echo "  --diagnose-framebuffer Show detailed framebuffer diagnostics"
            echo "  --fix-rainbow          Fix Raspberry Pi rainbow flash issues"
            echo "  --skip-build           Skip the build step"
            echo "  --systemd-only         Install systemd service only"
            echo "  --help, -h             Show this help message"
            echo ""
            echo "Auto-Update Features:"
            echo "  - AWS S3 auto-update functionality is included"
            echo "  - Set ART_FRAME_S3_BUCKET in .env to enable"
            echo "  - Use ./upload-to-s3.sh to upload new versions"
            echo "  - Use ./update.sh to manually check/apply updates"
            echo ""
            echo "Run without options to perform full setup"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check if script is being sourced or executed
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi 