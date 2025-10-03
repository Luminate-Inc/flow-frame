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
Designed for macOS - automatically delegates build to Lima Ubuntu VM.

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

    # Check for required tools
    local missing_tools=()
    for tool in git curl wget go; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        err "Missing required tools: ${missing_tools[*]}"
        info "Install with: sudo apt install ${missing_tools[*]}"
        exit 1
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
    info "Installing Armbian build dependencies in Lima VM..."

    if ! sudo -n true 2>/dev/null; then
        err "This script requires sudo access for installing dependencies"
        exit 1
    fi

    # Update package lists
    sudo apt-get update

    # Install Armbian build dependencies + cross-compilation tools
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
        libusb-1.0-0-dev \
        fakeroot \
        ntfs-3g \
        apt-cacher-ng \
        ca-certificates \
        gcc-aarch64-linux-gnu \
        g++-aarch64-linux-gnu \
        golang-go

    ok "Dependencies installed"
}

build_flow_frame_binary() {
    info "Cross-compiling flow-frame binary for ARM64..."

    cd "$PROJECT_DIR"

    # Check if Go module exists
    if [ ! -f "go.mod" ]; then
        err "No go.mod found in project directory"
        exit 1
    fi

    # Cross-compile for ARM64
    if ! CC=aarch64-linux-gnu-gcc CGO_ENABLED=1 GOOS=linux GOARCH=arm64 go build -o flow-frame; then
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
    mkdir -p userpatches/overlay/usr/local/bin
    cp "$PROJECT_DIR/flow-frame" userpatches/overlay/usr/local/bin/flow-frame
    chmod +x userpatches/overlay/usr/local/bin/flow-frame

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

            # Install Mesa + Panfrost drivers
            apt-get install -y \
                mesa-utils \
                mesa-vulkan-drivers \
                libdrm-tests \
                libgl1-mesa-dri \
                libgles2 \
                libdrm2 \
                libwayland-client0 \
                libwayland-egl1-mesa \
                weston

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

    ok "Armbian image built successfully: $BUILT_IMAGE"
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
