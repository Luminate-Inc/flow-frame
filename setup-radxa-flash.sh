#!/bin/bash

set -euo pipefail

# Setup script for creating Radxa Zero Armbian images with Panfrost GPU support
# Designed to run on macOS - automatically delegates to Ubuntu Lima VM

# Color codes and helper functions
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
        exit 1
    fi

    info "macOS detected - delegating to Lima Ubuntu VM"

    # Lima instance name
    local lima_instance="armbian-builder"

    # Check if instance exists
    if limactl list | tail -n +2 | grep -q "^${lima_instance}[[:space:]]"; then
        info "Using existing Lima VM: ${lima_instance}"
    else
        info "Creating Lima Debian VM: ${lima_instance}"
        # IMPORTANT: Use Debian 12 (Bookworm) to match target FFmpeg library versions
        # Ubuntu 24.04 has FFmpeg 6.x (libavformat60) but Debian Bookworm has FFmpeg 5.1.x (libavformat59)
        # Create with writable mount for the project directory and 8GB RAM
        limactl create --name="${lima_instance}" --memory=8 --mount="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd):w" template://debian-12
    fi

    # Start the instance if not running
    local instance_status=$(limactl list | tail -n +2 | grep "^${lima_instance}[[:space:]]" | awk '{print $2}' || echo "")
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

# Use writable directory when inside Lima VM
if [ -f "/.lima-vm" ] || [ -n "${LIMA_INSTANCE:-}" ]; then
    # Inside Lima VM - use home directory which is writable
    WORK_DIR="$HOME/armbian-work"
    info "Running in Lima VM - using writable work directory: $WORK_DIR"
else
    # Running natively on Linux - use project directory
    WORK_DIR="$PROJECT_DIR/armbian-work"
fi

ARMBIAN_DIR="$WORK_DIR/armbian-build"

# Configuration
BOARD="radxa-zero"
BRANCH="current"
RELEASE="bookworm"
KERNEL_CONFIGURE="no"
BUILD_MINIMAL="yes"
BUILD_DESKTOP="no"

show_usage() {
    cat <<USAGE
Usage: $0 [OPTIONS]

Build Armbian image with Panfrost GPU support for Radxa Zero.
Designed for macOS - automatically delegates build to Lima Debian VM.

OPTIONS:
    -h, --help          Show this help message
    -v, --verbose       Verbose output
    --clean             Clean previous build artifacts
    --board BOARD       Target board (default: radxa-zero)
    --release RELEASE   Debian release (default: bookworm)

EXAMPLES:
    # Basic build
    $0

    # Clean build
    $0 --clean

REQUIREMENTS:
    - macOS 10.15+ with Lima installed (brew install lima)
    - 20GB+ free disk space
    - Internet connection for downloading Armbian

OUTPUT:
    - Armbian image (.img file) in armbian-work/armbian-build/output/images/
    - Panfrost GPU drivers pre-configured

USAGE
}

check_requirements() {
    info "Checking system requirements..."

    local os_name="$(uname -s)"
    if [[ "$os_name" != "Linux" ]]; then
        err "This script should be running inside Lima VM (detected: $os_name)"
        exit 1
    fi

    info "Running inside Lima VM"

    # Verify we're on Debian (not Ubuntu) to ensure FFmpeg version compatibility
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" ]]; then
            err "This script requires Debian 12 (Bookworm) for FFmpeg library compatibility"
            err "Detected OS: $ID $VERSION_ID"
            err "Ubuntu has FFmpeg 6.x (libavformat60) but Armbian Bookworm needs FFmpeg 5.x (libavformat59)"
            exit 1
        fi
        if [[ "$VERSION_ID" != "12" ]]; then
            warn "Expected Debian 12 (Bookworm), detected: Debian $VERSION_ID"
            warn "FFmpeg library versions may not match target system"
        fi
        ok "Running on Debian $VERSION_ID ($VERSION_CODENAME)"
    fi

    # Check available disk space (need ~20GB)
    local available_space=$(df "$PROJECT_DIR" | awk 'NR==2 {print $4}')
    local required_space=$((20 * 1024 * 1024)) # 20GB in KB

    if [ "$available_space" -lt "$required_space" ]; then
        warn "Low disk space. Available: $(( available_space / 1024 / 1024 ))GB, Recommended: 20GB+"
        if [ -t 0 ]; then
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        else
            warn "Non-interactive mode - continuing anyway"
        fi
    fi

    ok "System requirements satisfied"
}

install_armbian_dependencies() {
    info "Installing Armbian build dependencies in Lima VM..."

    if ! sudo -n true 2>/dev/null; then
        err "This script requires sudo access for installing dependencies"
        exit 1
    fi

    # Add ARM64 architecture support for cross-compilation dependencies
    info "Adding arm64 architecture support..."
    sudo dpkg --add-architecture arm64

    # Update package lists
    sudo apt-get update

    # Install packages in groups for better error handling
    info "Installing core build tools..."
    if ! sudo apt-get install -y \
        git curl wget \
        build-essential \
        bison flex \
        libssl-dev \
        bc \
        u-boot-tools \
        python3 python3-pip; then
        err "Failed to install core build tools"
        exit 1
    fi

    info "Installing system utilities..."
    if ! sudo apt-get install -y \
        qemu-user-static \
        debootstrap \
        rsync \
        kmod cpio \
        unzip zip \
        fdisk gdisk \
        gpg \
        pigz pixz \
        ccache \
        distcc; then
        err "Failed to install system utilities"
        exit 1
    fi

    info "Installing filesystem tools..."
    if ! sudo apt-get install -y \
        f2fs-tools \
        mtools \
        parted \
        dosfstools \
        uuid-dev \
        zlib1g-dev \
        libusb-1.0-0-dev \
        fakeroot \
        ntfs-3g \
        apt-cacher-ng \
        ca-certificates; then
        err "Failed to install filesystem tools"
        exit 1
    fi

    info "Installing cross-compilation toolchain..."
    if ! sudo apt-get install -y \
        gcc-aarch64-linux-gnu \
        g++-aarch64-linux-gnu \
        golang; then
        err "Failed to install cross-compilation toolchain"
        exit 1
    fi

    # Install SDL2 and FFmpeg development libraries for ARM64 cross-compilation
    info "Installing SDL2 and FFmpeg development libraries for ARM64..."

    # IMPORTANT: FFmpeg versions must match target Debian Bookworm
    # Ubuntu may have different versions - verify compatibility
    # Bookworm uses FFmpeg 5.1.x with version 59 series libraries
    info "Checking FFmpeg library versions for compatibility..."

    sudo apt-get install -y \
        libsdl2-dev:arm64 \
        libsdl2-ttf-dev:arm64 \
        libavcodec-dev:arm64 \
        libavdevice-dev:arm64 \
        libavfilter-dev:arm64 \
        libavformat-dev:arm64 \
        libavutil-dev:arm64 \
        libswresample-dev:arm64 \
        libswscale-dev:arm64 \
        pkg-config

    # Display installed FFmpeg versions to verify compatibility
    info "Installed FFmpeg library versions:"
    dpkg -l | grep -E "libav(format|codec|device|filter|util)|libsw(scale|resample)" | grep arm64 | awk '{print $2, $3}'

    # Verify pkg-config can find the ARM64 libraries
    if PKG_CONFIG_PATH="/usr/lib/aarch64-linux-gnu/pkgconfig" pkg-config --exists libavformat; then
        ok "pkg-config successfully found ARM64 FFmpeg libraries"
        local avformat_version=$(PKG_CONFIG_PATH="/usr/lib/aarch64-linux-gnu/pkgconfig" pkg-config --modversion libavformat)
        info "libavformat version: $avformat_version"

        # Verify this is version 59.x (FFmpeg 5.x for Debian Bookworm compatibility)
        if [[ "$avformat_version" =~ ^59\. ]]; then
            ok "FFmpeg version is compatible with Debian Bookworm (version 59.x)"
        else
            err "FFmpeg version mismatch!"
            err "Expected: 59.x (FFmpeg 5.x for Debian Bookworm)"
            err "Found: $avformat_version"
            err "Binary will fail on target system with 'cannot open shared object file' error"
            exit 1
        fi
    else
        err "pkg-config cannot find ARM64 FFmpeg libraries"
        exit 1
    fi

    # Configure Go environment
    info "Configuring Go environment..."
    if ! grep -q 'export GOPATH=' ~/.profile 2>/dev/null; then
        echo 'export GOPATH=$HOME/go' >> ~/.profile
        echo 'export PATH=$PATH:$GOPATH/bin' >> ~/.profile
        info "Go environment variables added to ~/.profile"
    fi

    # Apply to current session
    export GOPATH=$HOME/go
    export PATH=$PATH:$GOPATH/bin

    ok "Dependencies installed and Go environment configured"
}

build_flow_frame_binary() {
    info "Cross-compiling flow-frame binary for ARM64..."

    cd "$PROJECT_DIR"

    # Check if Go module exists
    if [ ! -f "go.mod" ]; then
        err "No go.mod found in project directory"
        exit 1
    fi

    # Set PKG_CONFIG environment variables for ARM64 cross-compilation
    export PKG_CONFIG_PATH="/usr/lib/aarch64-linux-gnu/pkgconfig"
    export PKG_CONFIG_LIBDIR="/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="/"

    # Cross-compile for ARM64 with SDL2 support
    if ! CC=aarch64-linux-gnu-gcc \
         CGO_ENABLED=1 \
         GOOS=linux \
         GOARCH=arm64 \
         PKG_CONFIG_PATH="$PKG_CONFIG_PATH" \
         go build -o flow-frame; then
        err "Failed to cross-compile flow-frame binary"
        exit 1
    fi

    # Verify binary was created
    if [ ! -f "flow-frame" ]; then
        err "flow-frame binary not found after build"
        exit 1
    fi

    # Verify it's an ARM64 binary
    local binary_arch=$(file flow-frame | grep -o "ARM aarch64" || echo "")
    if [ -z "$binary_arch" ]; then
        err "Built binary is not ARM64 architecture"
        exit 1
    fi

    ok "flow-frame binary built successfully for ARM64"
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

create_panfrost_customizations() {
    info "Creating Panfrost GPU customizations..."

    cd "$ARMBIAN_DIR"

    # Create userpatches directory structure
    mkdir -p userpatches/overlay/{etc/modules-load.d,etc/modprobe.d,etc/udev/rules.d}

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

    # Copy flow-frame binary to overlay
    info "Copying flow-frame binary to image overlay..."
    if [ ! -f "$PROJECT_DIR/flow-frame" ]; then
        err "flow-frame binary not found at: $PROJECT_DIR/flow-frame"
        err "Run build_flow_frame_binary() first"
        exit 1
    fi

    mkdir -p userpatches/overlay/usr/local/bin
    if ! cp "$PROJECT_DIR/flow-frame" userpatches/overlay/usr/local/bin/flow-frame; then
        err "Failed to copy flow-frame binary to overlay"
        exit 1
    fi
    chmod +x userpatches/overlay/usr/local/bin/flow-frame
    ok "flow-frame binary copied successfully"

    # Copy assets/stock folder to overlay
    info "Copying assets/stock folder to image overlay..."
    if [ ! -d "$PROJECT_DIR/assets/stock" ]; then
        err "assets/stock directory not found at: $PROJECT_DIR/assets/stock"
        exit 1
    fi

    mkdir -p userpatches/overlay/opt/flowframe/assets
    if ! cp -r "$PROJECT_DIR/assets/stock/"* userpatches/overlay/opt/flowframe/assets/; then
        err "Failed to copy assets/stock to overlay"
        exit 1
    fi
    ok "assets/stock folder copied successfully"

    # Copy systemd service file to overlay
    info "Copying systemd service file to image overlay..."
    if [ ! -f "$PROJECT_DIR/flow-frame.service" ]; then
        err "flow-frame.service not found at: $PROJECT_DIR/flow-frame.service"
        err "Create the service file before running this script"
        exit 1
    fi

    mkdir -p userpatches/overlay/etc/systemd/system
    if ! cp "$PROJECT_DIR/flow-frame.service" userpatches/overlay/etc/systemd/system/flow-frame.service; then
        err "Failed to copy flow-frame.service to overlay"
        exit 1
    fi
    chmod 644 userpatches/overlay/etc/systemd/system/flow-frame.service

    # Verify files were copied successfully
    if [ ! -f "userpatches/overlay/usr/local/bin/flow-frame" ]; then
        err "Verification failed: flow-frame binary not in overlay"
        exit 1
    fi
    if [ ! -f "userpatches/overlay/etc/systemd/system/flow-frame.service" ]; then
        err "Verification failed: flow-frame.service not in overlay"
        exit 1
    fi
    ok "systemd service file copied and verified successfully"

    # Create minimal customize script that installs Mesa packages
    cat > userpatches/customize-image.sh <<'CUSTOMIZE'
#!/bin/bash

# Armbian image customization script
# Installs Panfrost GPU support (Mesa drivers)

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
            echo "=== Installing Panfrost GPU support ==="

            export DEBIAN_FRONTEND=noninteractive

            # Update package lists
            apt-get update

            # Install Mesa + Panfrost drivers + SDL2 runtime libraries + FFmpeg + NetworkManager
            # Note: ffmpeg package automatically pulls in all required libav* libraries
            # NetworkManager + dnsmasq are used for captive portal WiFi setup feature
            apt-get install -y \
                mesa-utils \
                mesa-vulkan-drivers \
                libdrm-tests \
                libgl1-mesa-dri \
                libgles2 \
                libdrm2 \
                libwayland-client0 \
                libwayland-egl1-mesa \
                weston \
                libsdl2-2.0-0 \
                libsdl2-ttf-2.0-0 \
                ffmpeg \
                network-manager \
                dnsmasq

            echo "✓ Panfrost GPU support installed"

            # Copy overlay files to rootfs
            # Note: Armbian makes overlay files available at /tmp/overlay
            echo "=== Copying overlay files to rootfs ==="
            if [ -d "/tmp/overlay" ]; then
                cp -rv /tmp/overlay/* / || echo "⚠ Warning: Failed to copy overlay files"
                echo "✓ Overlay files copied from /tmp/overlay"
            else
                echo "⚠ Warning: /tmp/overlay directory not found"
            fi

            # Verify flow-frame binary is in place
            if [ -f "/usr/local/bin/flow-frame" ]; then
                chmod +x /usr/local/bin/flow-frame
                echo "✓ flow-frame binary installed at /usr/local/bin/flow-frame"
                ls -lh /usr/local/bin/flow-frame
            else
                echo "⚠ Warning: flow-frame binary not found at /usr/local/bin/flow-frame"
            fi

            # Verify and set permissions for assets directory
            if [ -d "/opt/flowframe/assets" ]; then
                chmod -R 755 /opt/flowframe/assets
                echo "✓ assets directory installed at /opt/flowframe/assets"
                ls -lh /opt/flowframe/assets
            else
                echo "⚠ Warning: assets directory not found at /opt/flowframe/assets"
            fi

            # Create flowframe system user and group
            echo "=== Setting up flow-frame service user ==="
            if ! id flowframe >/dev/null 2>&1; then
                useradd -r -s /bin/false -d /opt/flowframe flowframe
                echo "✓ Created flowframe system user"
            else
                echo "ℹ flowframe user already exists"
            fi

            # Add flowframe user to video and render groups for GPU access
            usermod -aG video,render flowframe
            echo "✓ Added flowframe user to video and render groups"

            # Create working directory and set ownership
            mkdir -p /opt/flowframe
            chown -R flowframe:flowframe /opt/flowframe
            echo "✓ Created working directory /opt/flowframe with proper ownership"

            # Configure sudo permissions for flowframe user to manage WiFi and restart service
            echo "=== Configuring sudo permissions for flowframe user ==="
            cat > /etc/sudoers.d/flowframe <<'SUDOERS'
# Allow flowframe user to run nmcli for WiFi management without password
flowframe ALL=(ALL) NOPASSWD: /usr/bin/nmcli
# Allow flowframe user to restart its own service for updates
flowframe ALL=(ALL) NOPASSWD: /bin/systemctl restart flow-frame
SUDOERS
            chmod 440 /etc/sudoers.d/flowframe
            echo "✓ Configured sudo permissions for flowframe user"

            # Enable and start NetworkManager
            echo "=== Configuring NetworkManager ==="
            systemctl enable NetworkManager
            systemctl start NetworkManager || echo "ℹ NetworkManager will start on first boot"
            echo "✓ NetworkManager enabled and configured"

            # Create shared environment file with APP_VERSION
            echo "=== Creating shared environment file ==="
            cat > /opt/flowframe/.env <<'ENVFILE'
APP_VERSION=1
ENVFILE
            chown flowframe:flowframe /opt/flowframe/.env
            chmod 644 /opt/flowframe/.env
            echo "✓ Created /opt/flowframe/.env with APP_VERSION=1"

            # Enable and start flow-frame service
            echo "=== Configuring flow-frame systemd service ==="
            if [ -f "/etc/systemd/system/flow-frame.service" ]; then
                systemctl daemon-reload
                systemctl enable flow-frame.service
                echo "✓ flow-frame service enabled for boot"
                echo "ℹ Service will start automatically on first boot"
            else
                echo "⚠ Warning: flow-frame.service not found"
            fi
            ;;
    esac
}

Main "$@"
CUSTOMIZE

    chmod +x userpatches/customize-image.sh

    ok "Panfrost GPU customizations created"
}

build_armbian_image() {
    info "Building Armbian image with Panfrost support..."

    cd "$ARMBIAN_DIR"

    # Set build parameters
    local build_args=(
        "BOARD=$BOARD"
        "BRANCH=$BRANCH"
        "RELEASE=$RELEASE"
        "BUILD_MINIMAL=$BUILD_MINIMAL"
        "BUILD_DESKTOP=$BUILD_DESKTOP"
        "KERNEL_CONFIGURE=$KERNEL_CONFIGURE"
    )

    if [ "$VERBOSE" = true ]; then
        build_args+=("PROGRESS_LOG_TO_FILE=yes")
    fi

    info "Starting Armbian build with parameters: ${build_args[*]}"

    # Run build
    if ! ./compile.sh "${build_args[@]}"; then
        err "Armbian build failed"
        err "Check build logs for details"
        exit 1
    fi

    # Find the built image
    info "Searching for built image in output/images..."
    local built_image=$(find output/images -name "*.img" 2>/dev/null | head -1)

    if [ -z "$built_image" ]; then
        err "Build failed - no image found in output/images/"
        exit 1
    fi

    info "Found built image: $built_image"

    # Verify image is not empty
    local image_size=$(stat -c%s "$built_image" 2>/dev/null || stat -f%z "$built_image" 2>/dev/null)
    if [ "$image_size" -lt 10485760 ]; then  # Less than 10MB
        err "Built image appears corrupted (size: $image_size bytes)"
        exit 1
    fi

    info "Image size: $(numfmt --to=iec-i --suffix=B $image_size 2>/dev/null || echo "$image_size bytes")"

    BUILT_IMAGE="$built_image"

    # Copy image to project directory if we're in Lima VM
    if [ -f "/.lima-vm" ] || [ -n "${LIMA_INSTANCE:-}" ]; then
        local host_output_dir="$PROJECT_DIR/output"
        info "Copying built image to host-accessible location: $host_output_dir"

        # Try to create output directory (may fail if read-only, that's ok)
        mkdir -p "$host_output_dir" 2>/dev/null || true

        # If we can write, copy the image
        if [ -w "$PROJECT_DIR" ] || [ -w "$host_output_dir" ]; then
            cp "$built_image" "$host_output_dir/" && \
                info "Image copied to: $host_output_dir/$(basename "$built_image")" || \
                warn "Could not copy image to project directory (read-only filesystem)"
        else
            warn "Project directory is read-only, image remains at: $BUILT_IMAGE"
            info "To copy manually: limactl copy armbian-builder:$built_image ."
        fi
    fi

    ok "Armbian image built successfully: $BUILT_IMAGE"
}

cleanup() {
    if [ "$CLEAN_BUILD" = true ]; then
        info "Cleaning build artifacts..."

        # Preserve the Armbian git repository, only clean build outputs
        if [ -d "$ARMBIAN_DIR" ]; then
            info "Preserving Armbian repository, cleaning build artifacts only..."
            rm -rf "$ARMBIAN_DIR/output" 2>/dev/null || true
            rm -rf "$ARMBIAN_DIR/.tmp" 2>/dev/null || true
            rm -rf "$ARMBIAN_DIR/cache/sources" 2>/dev/null || true
            ok "Build artifacts cleaned (repository preserved)"
        else
            # If Armbian dir doesn't exist, clean everything
            rm -rf "$WORK_DIR" 2>/dev/null || true
            ok "Work directory cleaned"
        fi
    fi
}

main() {
    local VERBOSE=false
    local CLEAN_BUILD=false

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
            --clean)
                CLEAN_BUILD=true
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
            *)
                err "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    info "Radxa Zero Armbian + Panfrost Image Builder"
    info "Board: $BOARD"
    info "Release: $RELEASE"
    info ""

    # Execute the workflow
    check_requirements
    install_armbian_dependencies
    build_flow_frame_binary
    setup_armbian_build
    create_panfrost_customizations
    build_armbian_image
    cleanup

    ok "Radxa Zero image build complete!"
    info ""
    info "📁 Image location: $BUILT_IMAGE"
    info "🎯 Panfrost GPU drivers: pre-configured and installed"
    info ""
    info "Next steps:"
    info "1. Flash the image to SD card using Balena Etcher or dd"
    info "2. Boot Radxa Zero with the SD card"
    info "3. Complete Armbian first-boot setup"
    info "4. Verify GPU: lsmod | grep panfrost && ls -la /dev/dri/"
}

main "$@"
