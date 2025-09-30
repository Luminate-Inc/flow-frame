#!/bin/bash

set -euo pipefail

# Setup script for creating and flashing Radxa Zero images with Flow Frame
# Builds custom Armbian image with Panfrost GPU support and Flow Frame pre-installed

# Color codes and helper functions (needed early for delegation)
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC} $*"; }

# Detect if running on macOS and delegate to Lima VM if needed
detect_and_delegate_to_lima() {
    # Skip if we're already inside a Lima VM
    if [ -f "/.lima-vm" ] || [ -n "${LIMA_INSTANCE:-}" ]; then
        return 0
    fi

    # Only delegate on macOS
    if [[ "$(uname -s)" != "Darwin" ]]; then
        return 0
    fi

    # Check if limactl is available
    if ! command -v limactl >/dev/null 2>&1; then
        err "macOS detected but limactl is not installed"
        info "Install Lima with: brew install lima"
        info "Or use --docker flag to build with Docker instead"
        exit 1
    fi

    info "macOS detected - delegating to Lima Ubuntu VM"

    # Lima instance name
    local lima_instance="armbian-builder"

    # Check if instance exists
    if limactl list | grep -q "^${lima_instance}"; then
        info "Using existing Lima VM: ${lima_instance}"
    else
        info "Creating Lima Ubuntu VM: ${lima_instance}"
        limactl create --name="${lima_instance}" template://ubuntu-lts
    fi

    # Start the instance if not running
    local instance_status=$(limactl list | grep "^${lima_instance}" | awk '{print $2}' || echo "")
    if [[ "$instance_status" != "Running" ]]; then
        info "Starting Lima VM: ${lima_instance}"
        limactl start "${lima_instance}"
    fi

    # Get the absolute path of the project directory
    local project_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    info "Executing build inside Lima VM..."
    info "Project path: ${project_path}"

    # Copy script to Lima VM and execute with all original arguments
    limactl shell "${lima_instance}" bash -c "cd '${project_path}' && bash '${project_path}/$(basename "${BASH_SOURCE[0]}")' $*"

    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        ok "Build completed successfully in Lima VM"
    else
        err "Build failed in Lima VM with exit code: $exit_code"
    fi

    exit $exit_code
}

# Call delegation function before proceeding
detect_and_delegate_to_lima "$@"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$PROJECT_DIR/armbian-work"
ARMBIAN_DIR="$WORK_DIR/armbian-build"
OUTPUT_DIR="$WORK_DIR/output"

# Configuration
BOARD="radxa-zero"
BRANCH="current"
RELEASE="bookworm"
KERNEL_CONFIGURE="no"
BUILD_MINIMAL="no"
BUILD_DESKTOP="no"
TARGET_ARCH="linux-arm64"

show_usage() {
    cat <<USAGE
Usage: $0 [OPTIONS]

Build custom Armbian image with Flow Frame for Radxa Zero.
Creates downloadable .img file for flashing with Balena Etcher.

OPTIONS:
    -h, --help          Show this help message
    -v, --verbose       Verbose output
    --no-build          Skip building Flow Frame (use existing)
    --clean             Clean previous build artifacts
    --ssh-key FILE      Add SSH public key for root access
    --wifi-config       Include Wi-Fi configuration tools
    --board BOARD       Target board (default: radxa-zero)
    --release RELEASE   Debian release (default: bookworm)
    --output DIR        Output directory for images (default: ./images)
    --docker            Use Docker for Armbian build

EXAMPLES:
    # Basic build - creates downloadable image
    $0

    # Include SSH key and Wi-Fi config
    $0 --ssh-key ~/.ssh/id_rsa.pub --wifi-config

    # Use Docker build
    $0 --docker --ssh-key ~/.ssh/id_rsa.pub

    # Clean build with custom output directory
    $0 --clean --output ./my-images

REQUIREMENTS:
    - macOS 10.15+ (with Lima) or Linux
    - macOS: Install Lima with 'brew install lima'
    - Linux: No additional requirements
    - 20GB+ free disk space
    - Internet connection for downloading Armbian

OUTPUT:
    - Custom Armbian image (.img file)
    - Compressed image (.img.xz file) 
    - Flash instructions
    - Ready for Balena Etcher or dd

USAGE
}

check_requirements() {
    info "Checking system requirements..."

    # Check OS compatibility - now supports Linux and macOS via Lima
    local os_name="$(uname -s)"
    case "$os_name" in
        Darwin)
            # This shouldn't happen as macOS should delegate to Lima
            err "Running on macOS native - this should have been delegated to Lima"
            err "Please ensure limactl is installed and try again"
            exit 1
            ;;
        Linux)
            info "Running on Linux"
            OS_TYPE="linux"
            # Check if inside Lima VM
            if [ -f "/.lima-vm" ] || [ -n "${LIMA_INSTANCE:-}" ]; then
                info "Detected Lima VM environment"
            fi
            ;;
        *)
            err "Unsupported operating system: $os_name"
            err "This script requires Linux (or macOS with Lima)"
            exit 1
            ;;
    esac
    
    # Check for required tools
    local missing_tools=()
    for tool in git curl wget; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        err "Missing required tools: ${missing_tools[*]}"
        case "$OS_TYPE" in
            macos)
                info "Install with: brew install ${missing_tools[*]}"
                ;;
            linux)
                info "Install with: sudo apt install ${missing_tools[*]}"
                ;;
        esac
        exit 1
    fi
    
    # Check for Docker if using Docker build
    if [ "$USE_DOCKER" = true ]; then
        if ! command -v docker >/dev/null 2>&1; then
            err "Docker is required for this build method"
            info "Install with: sudo apt install docker.io"
            exit 1
        fi

        # Check if Docker is running
        if ! docker info >/dev/null 2>&1; then
            err "Docker is not running. Please start Docker and try again."
            exit 1
        fi

        info "Docker is available and running"
    fi
    
    # Check available disk space (need ~20GB)
    local available_space=$(df "$PROJECT_DIR" | awk 'NR==2 {print $4}')
    local required_space=$((20 * 1024 * 1024)) # 20GB in KB
    
    if [ "$available_space" -lt "$required_space" ]; then
        warn "Low disk space. Available: $(( available_space / 1024 / 1024 ))GB, Recommended: 20GB+"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    ok "System requirements satisfied"
}

install_armbian_dependencies() {
    # Skip dependency installation if using Docker
    if [ "$USE_DOCKER" = true ]; then
        info "Using Docker build - skipping local dependency installation"
        return 0
    fi

    info "Installing Armbian build dependencies on Linux..."
    
    # Check if we can install packages
    if ! sudo -n true 2>/dev/null; then
        err "This script requires sudo access for installing dependencies"
        exit 1
    fi
    
    # Update package lists
    sudo apt-get update
    
    # Install Armbian build dependencies
    sudo apt-get install -y \
        git curl wget \
        build-essential \
        bison flex \
        libssl-dev \
        bc \
        u-boot-tools \
        python3 python3-pip \
        qemu-user-static \
        debootstrap \
        rsync \
        kmod cpio \
        unzip zip \
        fdisk gdisk \
        gpg \
        pigz pixz \
        ccache \
        distcc \
        f2fs-tools \
        mtools \
        parted \
        dosfstools \
        uuid-dev \
        zlib1g-dev \
        unzip \
        libusb-1.0-0-dev \
        fakeroot \
        ntfs-3g \
        apt-cacher-ng \
        ca-certificates
    
    ok "Dependencies installed"
}

setup_armbian_build() {
    info "Setting up Armbian build environment..."
    
    # Create work directory
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    # Clone Armbian build system if not exists
    if [ ! -d "$ARMBIAN_DIR" ]; then
        info "Cloning Armbian build system..."
        git clone --depth=1 https://github.com/armbian/build armbian-build
    else
        info "Armbian build system already exists, updating..."
        cd "$ARMBIAN_DIR"
        git pull origin main || git pull origin master
        cd "$WORK_DIR"
    fi
    
    cd "$ARMBIAN_DIR"
    ok "Armbian build environment ready"
}

build_flow_frame() {
    if [ "$NO_BUILD_FLOW_FRAME" = true ]; then
        info "Skipping Flow Frame build (--no-build specified)"
        return 0
    fi
    
    info "Building Flow Frame for $TARGET_ARCH..."
    
    cd "$PROJECT_DIR"
    
    # Use Docker build if available for better reliability
    if command -v docker >/dev/null 2>&1; then
        ./build-debian.sh --docker "$TARGET_ARCH"
    else
        ./build-debian.sh "$TARGET_ARCH"
    fi
    
    # Verify build exists
    local package_file="$PROJECT_DIR/dist/flow-frame-${TARGET_ARCH}.tar.gz"
    if [ ! -f "$package_file" ]; then
        err "Flow Frame build failed - package not found: $package_file"
        exit 1
    fi
    
    ok "Flow Frame build complete: $package_file"
}

create_armbian_customizations() {
    info "Creating Armbian customizations..."
    
    cd "$ARMBIAN_DIR"
    
    # Create userpatches directory structure
    mkdir -p userpatches/{overlay,customize-image.sh.d}
    
    # Create overlay directory structure for our customizations
    mkdir -p userpatches/overlay/{etc/systemd/system,usr/local/bin,opt,etc/modules-load.d,etc/modprobe.d,etc/udev/rules.d,root/.ssh}
    
    create_panfrost_setup
    create_flow_frame_setup
    create_ssh_setup
    create_wifi_setup
    create_customize_script
    
    ok "Armbian customizations created"
}

create_panfrost_setup() {
    info "Creating Panfrost GPU configuration..."
    
    # Ensure Panfrost loads at boot
    cat > userpatches/overlay/etc/modules-load.d/panfrost.conf <<'EOF'
panfrost
EOF
    
    # Blacklist Lima driver (conflicts with Panfrost)
    cat > userpatches/overlay/etc/modprobe.d/blacklist-lima.conf <<'EOF'
blacklist lima
EOF
    
    # GPU permissions for render nodes
    cat > userpatches/overlay/etc/udev/rules.d/99-gpu-permissions.rules <<'EOF'
SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="video", MODE="0660"
SUBSYSTEM=="drm", KERNEL=="card*", GROUP="video", MODE="0660"
SUBSYSTEM=="graphics", KERNEL=="fb0", GROUP="video", MODE="0660"
EOF
    
    # Create GPU setup script
    cat > userpatches/overlay/usr/local/bin/setup-gpu.sh <<'GPUSETUP'
#!/bin/bash

set -euo pipefail

LOGFILE="/var/log/gpu-setup.log"

log() {
    echo "$(date): GPU Setup - $*" | tee -a "$LOGFILE"
}

log_err() {
    echo "$(date): GPU Setup ERROR - $*" | tee -a "$LOGFILE" >&2
}

log "=== Starting GPU setup for Radxa Zero (Mali G31 + Panfrost) ==="

# Install Mesa + test tools
export DEBIAN_FRONTEND=noninteractive

log "Updating package lists..."
if ! apt-get update; then
    log_err "Failed to update package lists"
    exit 1
fi

log "Installing Mesa and GPU tools..."
if apt-get install -y \
    mesa-utils mesa-vulkan-drivers libdrm-tests glmark2 kmscube \
    mesa-utils-extra libgl1-mesa-dri libgles2 \
    libvulkan1 vulkan-tools \
    libdrm2 libdrm-dev 2>&1 | tee -a "$LOGFILE"; then
    log "✓ Mesa and GPU tools installed successfully"
else
    log_err "✗ Failed to install some GPU packages (non-fatal, continuing)"
fi

# Ensure modules are loaded
log "Loading GPU kernel modules..."
if modprobe panfrost 2>/dev/null; then
    log "✓ Panfrost module loaded"
elif lsmod | grep -q panfrost; then
    log "✓ Panfrost module already loaded"
else
    log_err "✗ Failed to load panfrost module"
fi

if modprobe drm 2>/dev/null; then
    log "✓ DRM module loaded"
elif lsmod | grep -q drm; then
    log "✓ DRM module already loaded"
else
    log_err "✗ Failed to load DRM module"
fi

# Add users to video/render groups
log "Configuring user permissions..."
for user in armbian radxa root; do
    if id -u "$user" >/dev/null 2>&1; then
        if usermod -aG video,render "$user" 2>/dev/null; then
            log "✓ Added $user to video,render groups"
        else
            log_err "✗ Failed to add $user to groups"
        fi
    fi
done

# Make sure no software GL environment variables interfere
if grep -r "LIBGL_ALWAYS_SOFTWARE" /etc/ 2>/dev/null; then
    log_err "WARNING: Found LIBGL_ALWAYS_SOFTWARE settings that may interfere with hardware acceleration"
fi

# Test GPU functionality
log "Testing GPU functionality..."

if [ -c /dev/dri/renderD128 ]; then
    log "✓ GPU render node available: /dev/dri/renderD128"
    ls -la /dev/dri/ | tee -a "$LOGFILE"
else
    log_err "✗ GPU render node /dev/dri/renderD128 not found"
    if [ -d /dev/dri ]; then
        log "Available DRI devices:"
        ls -la /dev/dri/ | tee -a "$LOGFILE"
    else
        log_err "/dev/dri directory does not exist"
    fi
fi

if command -v glxinfo >/dev/null 2>&1; then
    log "Running glxinfo test..."
    glxinfo | grep -i "renderer\|version" | head -5 | tee -a "$LOGFILE" || log_err "glxinfo test failed"
else
    log "glxinfo not available for testing"
fi

log "=== GPU setup complete ==="
GPUSETUP
    
    chmod +x userpatches/overlay/usr/local/bin/setup-gpu.sh
    
    ok "Panfrost GPU configuration created"
}

create_flow_frame_setup() {
    set +e  # Don't exit on error so we can log it
    info "Creating Flow Frame setup..."

    local package_file="$PROJECT_DIR/dist/flow-frame-${TARGET_ARCH}.tar.gz"
    if [ ! -f "$package_file" ]; then
        warn "Flow Frame package not found: $package_file"
        warn "Package will need to be created during build"
        return 0
    fi

    info "Found Flow Frame package: $package_file"

    # Create directory structure FIRST
    info "Creating overlay directory structure"
    mkdir -p userpatches/overlay/opt/flow-frame/{bin,assets,config}

    # Extract Flow Frame package to temporary location
    local temp_extract="/tmp/flow-frame-extract"
    info "Extracting package to temporary location: $temp_extract"
    rm -rf "$temp_extract"
    mkdir -p "$temp_extract"

    if ! tar -xzf "$package_file" -C "$temp_extract"; then
        err "Failed to extract Flow Frame package"
        return 1
    fi

    # Verify extraction
    local package_name="flow-frame-${TARGET_ARCH}"
    if [ ! -d "$temp_extract/$package_name" ]; then
        err "Extraction failed: expected directory $temp_extract/$package_name not found"
        err "Contents of temp_extract:"
        ls -la "$temp_extract" | sed 's/^/  /'
        return 1
    fi

    info "Package structure:"
    find "$temp_extract/$package_name" -type f | sed 's/^/  /'

    # Copy Flow Frame files to overlay with proper paths
    info "Copying Flow Frame files to overlay"

    if [ -d "$temp_extract/$package_name/bin" ]; then
        cp -r "$temp_extract/$package_name"/bin/* userpatches/overlay/opt/flow-frame/bin/
        info "Copied binaries"
    else
        warn "No bin directory found in package"
    fi

    if [ -d "$temp_extract/$package_name/assets" ]; then
        cp -r "$temp_extract/$package_name"/assets/* userpatches/overlay/opt/flow-frame/assets/ 2>/dev/null || true
        info "Copied assets"
    else
        info "No assets directory found in package (optional)"
    fi

    if [ -d "$temp_extract/$package_name/config" ]; then
        cp -r "$temp_extract/$package_name"/config/* userpatches/overlay/opt/flow-frame/config/ 2>/dev/null || true
        info "Copied config files"
    else
        info "No config directory found in package (optional)"
    fi

    # Verify binary exists
    if [ ! -f userpatches/overlay/opt/flow-frame/bin/flow-frame ]; then
        err "Flow Frame binary not found after extraction at: userpatches/overlay/opt/flow-frame/bin/flow-frame"
        err "Contents of bin directory:"
        ls -la userpatches/overlay/opt/flow-frame/bin/ 2>/dev/null | sed 's/^/  /' || echo "  Directory does not exist"
        return 1
    fi

    # Ensure executable permissions
    chmod +x userpatches/overlay/opt/flow-frame/bin/flow-frame
    info "Set executable permissions on Flow Frame binary"

    # Copy .env file if it exists in project root
    if [ -f "$PROJECT_DIR/.env" ]; then
        cp "$PROJECT_DIR/.env" userpatches/overlay/opt/flow-frame/.env
        chmod 644 userpatches/overlay/opt/flow-frame/.env
        info "Copied .env file from project root"
    else
        warn "No .env file found at $PROJECT_DIR/.env - service may fail to start"
        warn "Create a .env file with your AWS credentials before building the image"
    fi

    # Create Flow Frame systemd service
    info "Creating Flow Frame systemd service"
    cat > userpatches/overlay/etc/systemd/system/flow-frame.service <<'FFSERVICE'
[Unit]
Description=Flow Frame
After=network-online.target multi-user.target gpu-setup.service
Wants=network-online.target
Requires=gpu-setup.service
StartLimitBurst=3
StartLimitIntervalSec=30

[Service]
Type=simple
User=flowframe
Group=flowframe
SupplementaryGroups=video render input
WorkingDirectory=/opt/flow-frame
ExecStart=/opt/flow-frame/bin/flow-frame
Restart=always
RestartSec=5
Environment=DISPLAY=:0
Environment=SDL_VIDEODRIVER=kmsdrm
EnvironmentFile=-/opt/flow-frame/.env
StandardOutput=journal
StandardError=journal
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
FFSERVICE
    
    # Create GPU setup service (runs before Flow Frame)
    cat > userpatches/overlay/etc/systemd/system/gpu-setup.service <<'GPUSERVICE'
[Unit]
Description=GPU Setup for Flow Frame
After=network-online.target
Wants=network-online.target
Before=flow-frame.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-gpu.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
GPUSERVICE
    
    # Create first-boot Flow Frame setup script
    cat > userpatches/overlay/usr/local/bin/setup-flow-frame.sh <<'FFSETUP'
#!/bin/bash

set -euo pipefail

LOGFILE="/var/log/flow-frame-setup.log"

log() {
    echo "$(date): Flow Frame Setup - $*" | tee -a "$LOGFILE"
}

log_err() {
    echo "$(date): Flow Frame Setup ERROR - $*" | tee -a "$LOGFILE" >&2
}

log "=== Starting Flow Frame setup ==="

# Verify installation directory exists
if [ ! -d /opt/flow-frame ]; then
    log_err "Flow Frame directory /opt/flow-frame does not exist!"
    exit 1
fi

# Verify binary exists
if [ ! -f /opt/flow-frame/bin/flow-frame ]; then
    log_err "Flow Frame binary not found at /opt/flow-frame/bin/flow-frame"
    ls -la /opt/flow-frame/ | tee -a "$LOGFILE" || true
    exit 1
fi

log "✓ Flow Frame binary found"

# Create service user
if ! id flowframe >/dev/null 2>&1; then
    log "Creating flowframe service user..."
    if useradd -r -s /usr/sbin/nologin -d /opt/flow-frame flowframe; then
        log "✓ Created flowframe user"
    else
        log_err "✗ Failed to create flowframe user"
        exit 1
    fi
else
    log "✓ flowframe user already exists"
fi

# Add to required groups
log "Adding flowframe user to required groups..."
if usermod -aG video,render,input flowframe 2>/dev/null; then
    log "✓ Added flowframe to video, render, input groups"
else
    log_err "✗ Failed to add flowframe to groups"
fi

# Set ownership and permissions
log "Setting ownership and permissions..."
if chown -R flowframe:flowframe /opt/flow-frame; then
    log "✓ Set ownership to flowframe:flowframe"
else
    log_err "✗ Failed to set ownership"
    exit 1
fi

if chmod 755 /opt/flow-frame/bin/flow-frame; then
    log "✓ Set executable permissions on binary"
else
    log_err "✗ Failed to set executable permissions"
    exit 1
fi

# Verify .env file
if [ -f /opt/flow-frame/.env ]; then
    log "✓ .env file present"
    chown flowframe:flowframe /opt/flow-frame/.env || true
    chmod 640 /opt/flow-frame/.env || true
else
    log_err "✗ .env file missing - service may fail"
fi

# Install runtime dependencies
log "Installing runtime dependencies..."
export DEBIAN_FRONTEND=noninteractive

if ! apt-get update; then
    log_err "Failed to update package lists"
    exit 1
fi

if apt-get install -y \
    libsdl2-2.0-0 libsdl2-ttf-2.0-0 \
    ffmpeg libdrm2 libgl1-mesa-dri \
    libwayland-client0 libwayland-egl1-mesa \
    awscli 2>&1 | tee -a "$LOGFILE"; then
    log "✓ Flow Frame dependencies installed successfully"
else
    log_err "✗ Failed to install some dependencies"
    exit 1
fi

# Enable and start services
log "Enabling systemd services..."

if systemctl enable gpu-setup.service 2>&1 | tee -a "$LOGFILE"; then
    log "✓ GPU setup service enabled"
else
    log_err "✗ Failed to enable GPU setup service"
fi

if systemctl enable flow-frame.service 2>&1 | tee -a "$LOGFILE"; then
    log "✓ Flow Frame service enabled"
else
    log_err "✗ Failed to enable Flow Frame service"
    exit 1
fi

# Verify service files exist
if [ ! -f /etc/systemd/system/flow-frame.service ]; then
    log_err "✗ Flow Frame service file missing!"
    exit 1
fi

log "=== Flow Frame setup complete ==="
log "Service will start automatically after reboot"
FFSETUP
    
    chmod +x userpatches/overlay/usr/local/bin/setup-flow-frame.sh
    
    # Cleanup temp extraction
    rm -rf "$temp_extract"

    # Final verification
    info "Verifying Flow Frame setup..."
    if [ -f userpatches/overlay/opt/flow-frame/bin/flow-frame ]; then
        info "✓ Binary exists and is executable"
        ls -lh userpatches/overlay/opt/flow-frame/bin/flow-frame | sed 's/^/  /'
    else
        err "✗ Binary missing after setup"
        set -e
        return 1
    fi

    if [ -f userpatches/overlay/opt/flow-frame/.env ]; then
        info "✓ .env file present"
    else
        warn "✗ .env file missing (may cause service failure)"
    fi

    if [ -f userpatches/overlay/etc/systemd/system/flow-frame.service ]; then
        info "✓ Systemd service file created"
    else
        err "✗ Systemd service file missing"
        set -e
        return 1
    fi

    set -e  # Re-enable exit on error
    ok "Flow Frame setup created and verified"
}

create_ssh_setup() {
    info "Creating SSH configuration..."
    
    # Add SSH key if provided
    if [ -n "$SSH_KEY_FILE" ] && [ -f "$SSH_KEY_FILE" ]; then
        cp "$SSH_KEY_FILE" userpatches/overlay/root/.ssh/authorized_keys
        chmod 600 userpatches/overlay/root/.ssh/authorized_keys
        info "SSH key added from: $SSH_KEY_FILE"
    fi
    
    # Create SSH setup script
    cat > userpatches/overlay/usr/local/bin/setup-ssh.sh <<'SSHSETUP'
#!/bin/bash

set -euo pipefail

log() {
    echo "$(date): SSH Setup - $*" | tee -a /var/log/ssh-setup.log
}

log "Configuring SSH access"

# Install OpenSSH server if not present
if ! command -v sshd >/dev/null 2>&1; then
    apt-get update
    apt-get install -y openssh-server
fi

# Enable SSH service
systemctl enable ssh
systemctl start ssh

# Configure SSH for security
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

# Restart SSH to apply changes
systemctl restart ssh

log "SSH configuration complete"
SSHSETUP
    
    chmod +x userpatches/overlay/usr/local/bin/setup-ssh.sh
    
    ok "SSH configuration created"
}

create_wifi_setup() {
    if [ "$INCLUDE_WIFI" != true ]; then
        return 0
    fi
    
    info "Creating Wi-Fi configuration..."
    
    # Create Wi-Fi setup script
    cat > userpatches/overlay/usr/local/bin/setup-wifi.sh <<'WIFISETUP'
#!/bin/bash

# Wi-Fi configuration script for Radxa Zero
# Usage: setup-wifi.sh "SSID" "PASSWORD"

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 \"SSID\" \"PASSWORD\""
    exit 1
fi

SSID="$1"
PASSWORD="$2"

log() {
    echo "$(date): Wi-Fi Setup - $*" | tee -a /var/log/wifi-setup.log
}

log "Configuring Wi-Fi for SSID: $SSID"

# Install Wi-Fi tools if needed
apt-get update
apt-get install -y wpasupplicant wireless-tools rfkill

# Create wpa_supplicant configuration
cat > /etc/wpa_supplicant/wpa_supplicant.conf <<WPACONF
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="$SSID"
    psk="$PASSWORD"
}
WPACONF

# Enable Wi-Fi interface
rfkill unblock wifi || true

# Restart networking services
systemctl restart wpa_supplicant
systemctl restart networking

log "Wi-Fi configured. Reboot to apply changes: sudo reboot"
WIFISETUP
    
    chmod +x userpatches/overlay/usr/local/bin/setup-wifi.sh
    
    # Create Wi-Fi readme
    cat > userpatches/overlay/root/WIFI-SETUP.txt <<'WIFIREADME'
Wi-Fi Configuration Instructions
===============================

To configure Wi-Fi on this Radxa Zero:

1. Connect via Ethernet or serial console
2. Run: sudo /usr/local/bin/setup-wifi.sh "YourSSID" "YourPassword"
3. Reboot: sudo reboot

The device will then connect to your Wi-Fi network automatically.
Flow Frame will start automatically after boot.
WIFIREADME
    
    ok "Wi-Fi configuration created"
}

create_customize_script() {
    info "Creating Armbian customize script..."
    
    # Main customization script that runs during image build
    cat > userpatches/customize-image.sh <<'CUSTOMIZE'
#!/bin/bash

# Armbian image customization script
# This runs during the image build process
# Arguments: $RELEASE $LINUXFAMILY $BOARD $BUILD_DESKTOP $ARCH

set -euo pipefail

# Assign parameters from Armbian build system
RELEASE=$1
LINUXFAMILY=$2
BOARD=$3
BUILD_DESKTOP=$4
ARCH=$5

Main() {
    case $RELEASE in
        bookworm|bullseye|jammy|focal)
            # Enable SSH by default
            systemctl enable ssh
            
            # Create setup service that runs on first boot
            cat > /etc/systemd/system/radxa-first-boot.service <<'FIRSTBOOT'
[Unit]
Description=Radxa Zero First Boot Setup
After=network-online.target
Wants=network-online.target
Before=flow-frame.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/radxa-first-boot.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
FIRSTBOOT
            
            # Create first boot setup script
            cat > /usr/local/bin/radxa-first-boot.sh <<'FIRSTBOOTSCRIPT'
#!/bin/bash

set -euo pipefail

LOGFILE="/var/log/radxa-first-boot.log"
FAILED=0

log() {
    echo "$(date): $*" | tee -a "$LOGFILE"
}

log_err() {
    echo "$(date): ERROR - $*" | tee -a "$LOGFILE" >&2
}

run_setup() {
    local script=$1
    local name=$2

    log "=== Running $name setup ==="

    if [ ! -f "$script" ]; then
        log_err "$name setup script not found: $script"
        FAILED=1
        return 1
    fi

    if [ ! -x "$script" ]; then
        log_err "$name setup script is not executable: $script"
        chmod +x "$script" || true
    fi

    if "$script" 2>&1 | tee -a "$LOGFILE"; then
        log "✓ $name setup completed successfully"
        return 0
    else
        log_err "✗ $name setup failed with exit code: $?"
        FAILED=1
        return 1
    fi
}

log "=== Radxa Zero First Boot Setup Starting ==="
log "System: $(uname -a)"
log "Date: $(date)"

# Wait for network to be fully ready
log "Waiting for network..."
sleep 5

# Acquire dpkg lock by waiting for any running apt operations
log "Checking for running package operations..."
timeout=60
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
      fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
      fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    log "Waiting for other package operations to finish..."
    sleep 5
    timeout=$((timeout - 5))
    if [ $timeout -le 0 ]; then
        log_err "Timeout waiting for package lock"
        break
    fi
done

# Run setup scripts sequentially with error handling
run_setup /usr/local/bin/setup-ssh.sh "SSH" || true
run_setup /usr/local/bin/setup-gpu.sh "GPU" || true
run_setup /usr/local/bin/setup-flow-frame.sh "Flow Frame" || true

if [ $FAILED -eq 0 ]; then
    log "=== All first boot setup tasks completed successfully ==="
else
    log_err "=== First boot setup completed WITH ERRORS - check log above ==="
fi

# Disable this service so it doesn't run again
systemctl disable radxa-first-boot.service

log "=== First boot service disabled ==="
log "=== Logs saved to $LOGFILE ==="

exit $FAILED
FIRSTBOOTSCRIPT
            
            chmod +x /usr/local/bin/radxa-first-boot.sh
            
            # Enable first boot service
            systemctl enable radxa-first-boot.service
            
            # Set up automatic login for easier debugging (optional)
            # systemctl enable getty@tty1.service
            
            ;;
    esac
}

Main "$@"
CUSTOMIZE
    
    chmod +x userpatches/customize-image.sh
    
    ok "Armbian customize script created"
}

build_armbian_image() {
    info "Building Armbian image with customizations..."

    cd "$ARMBIAN_DIR"

    # Verify customizations are in place before building
    info "Verifying customizations before build..."
    if [ -f userpatches/customize-image.sh ]; then
        info "✓ customize-image.sh present"
    else
        err "✗ customize-image.sh missing"
        exit 1
    fi

    if [ -f userpatches/overlay/opt/flow-frame/bin/flow-frame ]; then
        info "✓ Flow Frame binary in overlay"
    else
        warn "✗ Flow Frame binary not in overlay (may be added later)"
    fi

    # Set build parameters
    local build_args=(
        "BOARD=$BOARD"
        "BRANCH=$BRANCH"
        "RELEASE=$RELEASE"
        "BUILD_MINIMAL=$BUILD_MINIMAL"
        "BUILD_DESKTOP=$BUILD_DESKTOP"
        "KERNEL_CONFIGURE=$KERNEL_CONFIGURE"
        "EXPERT=yes"
        "CREATE_PATCHES=no"
        "BUILD_KSRC=no"
    )

    if [ "$VERBOSE" = true ]; then
        build_args+=("PROGRESS_LOG_TO_FILE=yes")
    fi

    # Add Docker-specific parameters if using Docker
    if [ "$USE_DOCKER" = true ]; then
        build_args+=("DOCKER_ARMBIAN_BUILD=yes")
        info "Using Docker for Armbian build"
    fi

    info "Starting Armbian build with parameters: ${build_args[*]}"

    # Run the build (with or without Docker)
    if [ "$USE_DOCKER" = true ]; then
        # Use Armbian's Docker build system
        if ! ./compile.sh "${build_args[@]}" DOCKER_ARMBIAN_BUILD=yes; then
            err "Armbian build failed"
            err "Check build logs for details"
            exit 1
        fi
    else
        # Native build
        if ! ./compile.sh "${build_args[@]}"; then
            err "Armbian build failed"
            err "Check build logs for details"
            exit 1
        fi
    fi

    # Find the built image
    info "Searching for built image in output/images..."
    local built_image=$(find output/images -name "*.img" 2>/dev/null | head -1)

    if [ -z "$built_image" ]; then
        err "Build failed - no image found in output/images/"
        err "Contents of output/images:"
        ls -la output/images/ 2>/dev/null | sed 's/^/  /' || echo "  Directory does not exist"
        exit 1
    fi

    info "Found built image: $built_image"

    # Verify image is not empty
    local image_size=$(stat -f%z "$built_image" 2>/dev/null || stat -c%s "$built_image" 2>/dev/null)
    if [ "$image_size" -lt 10485760 ]; then  # Less than 10MB
        err "Built image appears corrupted (size: $image_size bytes)"
        exit 1
    fi

    info "Image size: $(numfmt --to=iec-i --suffix=B $image_size 2>/dev/null || echo "$image_size bytes")"

    # Copy to our output directory with descriptive name
    mkdir -p "$OUTPUT_DIR"
    local timestamp=$(date +%Y%m%d-%H%M)
    local output_name="radxa-zero-flowframe-${timestamp}.img"

    info "Copying image to output directory..."
    if ! cp "$built_image" "$OUTPUT_DIR/$output_name"; then
        err "Failed to copy image to output directory"
        exit 1
    fi

    BUILT_IMAGE="$OUTPUT_DIR/$output_name"

    ok "Armbian image built successfully: $BUILT_IMAGE"
}

compress_and_prepare_image() {
    info "Preparing final image files..."
    
    # Get image size
    local image_size=$(du -h "$BUILT_IMAGE" | cut -f1)
    info "Original image size: $image_size"
    
    # Create compressed version
    info "Compressing image for distribution..."
    if command -v xz >/dev/null 2>&1; then
        xz -9 -T0 -k "$BUILT_IMAGE"
        local compressed_image="${BUILT_IMAGE}.xz"
        local compressed_size=$(du -h "$compressed_image" | cut -f1)
        info "Compressed image: $compressed_size"
        
        # Create checksum
        if command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$compressed_image" > "${compressed_image}.sha256"
        elif command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$compressed_image" > "${compressed_image}.sha256"
        fi
        
        COMPRESSED_IMAGE="$compressed_image"
    else
        warn "xz not available - skipping compression"
        COMPRESSED_IMAGE=""
    fi
    
    ok "Image files prepared in: $OUTPUT_DIR"
}

create_flash_instructions() {
    info "Creating flash instructions..."
    
    local image_filename=$(basename "$BUILT_IMAGE")
    local compressed_filename=""
    if [ -n "$COMPRESSED_IMAGE" ]; then
        compressed_filename=$(basename "$COMPRESSED_IMAGE")
    fi
    
    cat > "$OUTPUT_DIR/FLASH-INSTRUCTIONS.txt" <<INSTRUCTIONS
Radxa Zero Flow Frame - Flash Instructions
=========================================

Built: $(date)
Platform: Radxa Zero (ARM64) with Mali G31 GPU
OS: Custom Armbian with Flow Frame pre-installed

IMAGE FILES:
- Original: $image_filename
$([ -n "$compressed_filename" ] && echo "- Compressed: $compressed_filename (recommended)")
$([ -n "$compressed_filename" ] && echo "- Checksum: ${compressed_filename}.sha256")

FLASHING OPTIONS:

Option 1: Balena Etcher (Recommended)
=====================================
1. Download and install Balena Etcher: https://www.balena.io/etcher/
2. Launch Balena Etcher
3. Select image file: $image_filename$([ -n "$compressed_filename" ] && echo " or $compressed_filename")
4. Select your SD card (8GB+ recommended)
5. Click "Flash!"
6. Wait for completion and verification

Option 2: Command Line (Linux/macOS)
===================================
1. Insert SD card and identify device:
   # macOS:
   diskutil list
   
   # Linux:
   lsblk

2. Unmount the SD card:
   # macOS:
   diskutil unmountDisk /dev/diskX
   
   # Linux:
   sudo umount /dev/sdX*

3. Flash the image:
$(if [ -n "$compressed_filename" ]; then
    echo "   # Using compressed image:"
    echo "   xz -dc $compressed_filename | sudo dd of=/dev/diskX bs=4M status=progress"
    echo "   "
    echo "   # Or using original image:"
fi)
   sudo dd if=$image_filename of=/dev/diskX bs=4M status=progress
   sync
   
   CAUTION: Replace /dev/diskX with your actual SD card device!

4. Eject SD card:
   # macOS:
   diskutil eject /dev/diskX
   
   # Linux:
   sudo eject /dev/sdX

FIRST BOOT SEQUENCE:
===================
1. Insert SD card into Radxa Zero and power on
2. Initial boot (30 seconds) - SSH becomes available
3. Auto-configuration (2-3 minutes):
   - Install GPU drivers (Mesa + Panfrost)
   - Install Flow Frame dependencies (SDL2, FFmpeg)
   - Configure service user and permissions
   - Start Flow Frame service
4. Flow Frame starts with GPU acceleration
5. System ready for use

DEFAULT CREDENTIALS:
===================
- Username: root
- Password: 1234 (you'll be prompted to change on first login)
$([ -n "$SSH_KEY_FILE" ] && echo "- SSH: Key-based authentication enabled")

NETWORK CONFIGURATION:
=====================
- Ethernet: DHCP enabled by default
$([ "$INCLUDE_WIFI" = true ] && echo "- Wi-Fi: Configure with setup script (see below)")

SERVICES AND MONITORING:
=======================
# Check Flow Frame status
sudo systemctl status flow-frame

# View Flow Frame logs (live)
sudo journalctl -u flow-frame -f

# Check GPU setup
sudo systemctl status gpu-setup
sudo journalctl -u gpu-setup -f

# Check first-boot setup
sudo journalctl -u radxa-first-boot

# Verify GPU acceleration
glxinfo | grep -i renderer
ls -la /dev/dri/

# Test GPU performance
glmark2-es2
INSTRUCTIONS

    if [ "$INCLUDE_WIFI" = true ]; then
        cat >> "$OUTPUT_DIR/FLASH-INSTRUCTIONS.txt" <<WIFI_INST

WI-FI SETUP:
============
1. Connect via Ethernet or serial console
2. Configure Wi-Fi:
   sudo /usr/local/bin/setup-wifi.sh "YourSSID" "YourPassword"
3. Reboot to apply:
   sudo reboot

WIFI_INST
    fi

    if [ -n "$SSH_KEY_FILE" ]; then
        cat >> "$OUTPUT_DIR/FLASH-INSTRUCTIONS.txt" <<SSH_INST

SSH ACCESS:
===========
- SSH is enabled with your public key pre-installed
- Connect: ssh root@<radxa-zero-ip>
- Find IP: Check router or use: nmap -sn 192.168.1.0/24

SSH_INST
    fi

    cat >> "$OUTPUT_DIR/FLASH-INSTRUCTIONS.txt" <<FOOTER

TROUBLESHOOTING:
===============
# Flow Frame won't start
sudo systemctl restart flow-frame
sudo journalctl -u flow-frame -f

# GPU acceleration issues  
sudo journalctl -u gpu-setup -f
lsmod | grep panfrost
glxinfo | grep renderer

# Network issues
ip addr show
sudo systemctl restart networking

# Check system resources
htop
df -h
free -h

FILE VERIFICATION:
=================
$([ -n "$compressed_filename" ] && echo "# Verify compressed image integrity")
$([ -n "$compressed_filename" ] && echo "sha256sum -c ${compressed_filename}.sha256")

SUPPORT:
========
- Check logs first using commands above
- Flow Frame should start automatically after first-boot completes
- GPU acceleration requires proper Panfrost driver loading
- First boot takes longer due to one-time configuration

Built on: $(date)
Build system: $(uname -s) $(uname -m)
$([ "$USE_DOCKER" = true ] && echo "Build method: Docker")
$([ "$USE_DOCKER" != true ] && echo "Build method: Native")
FOOTER

    ok "Flash instructions created: $OUTPUT_DIR/FLASH-INSTRUCTIONS.txt"
}

cleanup() {
    if [ "$CLEAN_BUILD" = true ]; then
        info "Cleaning build artifacts..."
        rm -rf "$WORK_DIR" 2>/dev/null || true
        ok "Build artifacts cleaned"
    fi
}

main() {
    local VERBOSE=false
    local NO_BUILD_FLOW_FRAME=false
    local CLEAN_BUILD=false
    local SSH_KEY_FILE=""
    local INCLUDE_WIFI=false
    local USE_DOCKER=false
    
    # Set default output directory
    OUTPUT_DIR="$PROJECT_DIR/images"

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                set -x
                shift
                ;;
            --no-build)
                NO_BUILD_FLOW_FRAME=true
                shift
                ;;
            --clean)
                CLEAN_BUILD=true
                shift
                ;;
            --ssh-key)
                SSH_KEY_FILE="$2"
                if [ ! -f "$SSH_KEY_FILE" ]; then
                    err "SSH key file not found: $SSH_KEY_FILE"
                    exit 1
                fi
                shift 2
                ;;
            --wifi-config)
                INCLUDE_WIFI=true
                shift
                ;;
            --board)
                BOARD="$2"
                shift 2
                ;;
            --release)
                RELEASE="$2"
                shift 2
                ;;
            --output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --docker)
                USE_DOCKER=true
                shift
                ;;
            *)
                err "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    info "Radxa Zero Flow Frame Image Builder"
    info "Board: $BOARD"
    info "Release: $RELEASE" 
    info "Target architecture: $TARGET_ARCH"
    info "Output directory: $OUTPUT_DIR"
    
    if [ "$USE_DOCKER" = true ]; then
        info "Build method: Docker"
    else
        info "Build method: Native"
    fi
    
    if [ "$INCLUDE_WIFI" = true ]; then
        info "Wi-Fi configuration: enabled"
    fi
    
    if [ -n "$SSH_KEY_FILE" ]; then
        info "SSH key: $SSH_KEY_FILE"
    fi
    
    # Execute the workflow with error handling
    info "=== Starting build workflow ==="

    if ! check_requirements; then
        err "Requirements check failed"
        exit 1
    fi

    if ! install_armbian_dependencies; then
        err "Failed to install Armbian dependencies"
        exit 1
    fi

    if ! setup_armbian_build; then
        err "Failed to setup Armbian build environment"
        exit 1
    fi

    if ! build_flow_frame; then
        err "Failed to build Flow Frame"
        exit 1
    fi

    if ! create_armbian_customizations; then
        err "Failed to create Armbian customizations"
        exit 1
    fi

    if ! build_armbian_image; then
        err "Failed to build Armbian image"
        exit 1
    fi

    if ! compress_and_prepare_image; then
        err "Failed to compress and prepare image"
        exit 1
    fi

    if ! create_flash_instructions; then
        err "Failed to create flash instructions"
        exit 1
    fi

    cleanup
    
    ok "Radxa Zero image build complete!"
    info ""
    info "📁 Output directory: $OUTPUT_DIR"
    info "🖼️  Image file: $(basename "$BUILT_IMAGE")"
    if [ -n "$COMPRESSED_IMAGE" ]; then
        info "📦 Compressed: $(basename "$COMPRESSED_IMAGE")"
        info "🔒 Checksum: $(basename "$COMPRESSED_IMAGE").sha256"
    fi
    info "📋 Instructions: FLASH-INSTRUCTIONS.txt"
    info ""
    info "🎯 Next steps:"
    info "1. Use Balena Etcher to flash the image to SD card"
    if [ -n "$COMPRESSED_IMAGE" ]; then
        info "   - Recommended: $(basename "$COMPRESSED_IMAGE")"
    fi
    info "2. Insert SD card into Radxa Zero and power on"
    info "3. Wait 2-3 minutes for auto-configuration"
    info "4. Flow Frame will start automatically with GPU acceleration"
    info ""
    info "💡 For detailed instructions, see: $OUTPUT_DIR/FLASH-INSTRUCTIONS.txt"
}

main "$@"
