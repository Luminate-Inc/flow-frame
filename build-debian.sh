#!/bin/bash

# Cross-compilation build script for Flow Frame
# Creates standalone executables for various Debian/Linux targets

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC} $*"; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="flow-frame"

# Target architectures and their Go GOARCH values
# Format: target:goarch
# Scoped to Radxa Zero (ARM64) target only
TARGETS=(
    "linux-arm64:arm64"
)

# ARM variants
# Format: target:goarm
# Not needed for ARM64 target
ARM_VARIANTS=()

# Helper functions for working with target arrays
get_target_arch() {
    local target=$1
    for entry in "${TARGETS[@]}"; do
        if [[ "${entry%%:*}" == "$target" ]]; then
            echo "${entry##*:}"
            return 0
        fi
    done
    return 1
}

get_arm_variant() {
    local target=$1
    for entry in "${ARM_VARIANTS[@]}"; do
        if [[ "${entry%%:*}" == "$target" ]]; then
            echo "${entry##*:}"
            return 0
        fi
    done
    return 1
}

is_valid_target() {
    local target=$1
    for entry in "${TARGETS[@]}"; do
        if [[ "${entry%%:*}" == "$target" ]]; then
            return 0
        fi
    done
    return 1
}

get_all_targets() {
    for entry in "${TARGETS[@]}"; do
        echo "${entry%%:*}"
    done
}

# Enable strict mode after declaring arrays and functions
set -euo pipefail

cleanup() {
    info "Cleaning up build directories"
    rm -rf "$BUILD_DIR" "$DIST_DIR"
}

prepare_build_env() {
    info "Preparing build environment"
    
    # Check if Go is installed
    if ! command -v go >/dev/null 2>&1; then
        err "Go is not installed. Please install Go 1.23.1 or later."
        exit 1
    fi
    
    # Verify Go version
    GO_VERSION=$(go version | sed -n 's/.*go\([0-9][^ ]*\).*/\1/p')
    info "Using Go version: $GO_VERSION"
    
    # Create build directories
    mkdir -p "$BUILD_DIR" "$DIST_DIR"
    
    # Download dependencies
    info "Downloading Go dependencies"
    cd "$PROJECT_DIR"
    go mod download
    go mod tidy
    
    ok "Build environment ready"
}

build_for_target() {
    local target=$1
    local arch=$(get_target_arch "$target")
    local output_name="${APP_NAME}-${target}"
    
    if [[ -z "$arch" ]]; then
        err "Unknown target: $target"
        return 1
    fi
    
    info "Building for $target (GOARCH=$arch)"
    
    cd "$PROJECT_DIR"
    
    # Set environment variables for cross-compilation
    export GOOS=linux
    export GOARCH=$arch
    export CGO_ENABLED=1
    
    # Set ARM variant if applicable
    if [[ "$target" == *"armv"* ]]; then
        local goarm=$(get_arm_variant "$target")
        if [[ -n "$goarm" ]]; then
            export GOARM=$goarm
            info "Using ARM variant: GOARM=$GOARM"
        fi
    fi
    
    # Set C compiler for cross-compilation
    case "$target" in
        "linux-amd64")
            export CC=x86_64-linux-gnu-gcc
            ;;
        "linux-arm64")
            export CC=aarch64-linux-gnu-gcc
            ;;
        "linux-armv7"|"linux-armv6")
            export CC=arm-linux-gnueabihf-gcc
            ;;
    esac
    
    # Build flags for static linking and optimization
    BUILD_FLAGS=(
        -v
        -ldflags "-s -w -extldflags '-static-libgcc'"
        -tags "static,netgo"
        -trimpath
    )
    
    # Build the executable
    if go build "${BUILD_FLAGS[@]}" -o "$BUILD_DIR/$output_name" .; then
        ok "Built $output_name successfully"
        
        # Get file info
        local size=$(du -h "$BUILD_DIR/$output_name" | cut -f1)
        info "Executable size: $size"
        
        # Verify the binary
        file "$BUILD_DIR/$output_name"
        
        return 0
    else
        err "Failed to build $output_name"
        return 1
    fi
}

install_cross_compilers() {
    info "Checking cross-compilation toolchains"
    
    local missing_compilers=()
    
    # Check for required cross-compilers
    if ! command -v x86_64-linux-gnu-gcc >/dev/null 2>&1; then
        missing_compilers+=("gcc-x86-64-linux-gnu")
    fi
    
    if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
        missing_compilers+=("gcc-aarch64-linux-gnu")
    fi
    
    if ! command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1; then
        missing_compilers+=("gcc-arm-linux-gnueabihf")
    fi
    
    if [ ${#missing_compilers[@]} -gt 0 ]; then
        warn "Missing cross-compilers: ${missing_compilers[*]}"
        info "Installing cross-compilation toolchains..."
        
        case "$(uname -s)" in
            Darwin)
                if command -v brew >/dev/null 2>&1; then
                    # On macOS, we'll use Docker for cross-compilation instead
                    warn "Cross-compilation on macOS requires Docker. Consider using the Docker build option."
                else
                    err "Homebrew not found. Please install cross-compilation toolchains manually."
                    exit 1
                fi
                ;;
            Linux)
                if command -v apt-get >/dev/null 2>&1; then
                    sudo apt-get update
                    for compiler in "${missing_compilers[@]}"; do
                        sudo apt-get install -y "$compiler"
                    done
                elif command -v dnf >/dev/null 2>&1; then
                    for compiler in "${missing_compilers[@]}"; do
                        # Convert Debian package names to Fedora equivalents
                        case "$compiler" in
                            "gcc-x86-64-linux-gnu") sudo dnf install -y gcc ;;
                            "gcc-aarch64-linux-gnu") sudo dnf install -y gcc-aarch64-linux-gnu ;;
                            "gcc-arm-linux-gnueabihf") sudo dnf install -y gcc-arm-linux-gnu ;;
                        esac
                    done
                else
                    err "Unsupported package manager. Please install cross-compilation toolchains manually."
                    exit 1
                fi
                ;;
            *)
                err "Unsupported operating system for cross-compilation setup"
                exit 1
                ;;
        esac
        
        ok "Cross-compilation toolchains installed"
    else
        ok "All required cross-compilers are available"
    fi
}

create_deployment_package() {
    local target=$1
    local binary_name="${APP_NAME}-${target}"
    local package_dir="$DIST_DIR/${APP_NAME}-${target}"
    
    info "Creating deployment package for $target"
    
    # Create package directory structure
    mkdir -p "$package_dir"/{bin,assets,config}
    
    # Copy the binary
    cp "$BUILD_DIR/$binary_name" "$package_dir/bin/$APP_NAME"
    chmod +x "$package_dir/bin/$APP_NAME"
    
    # Copy assets if they exist
    if [ -d "$PROJECT_DIR/assets" ]; then
        cp -r "$PROJECT_DIR/assets"/* "$package_dir/assets/"
    fi
    
    # Copy configuration files
    [ -f "$PROJECT_DIR/settings.json" ] && cp "$PROJECT_DIR/settings.json" "$package_dir/config/"
    [ -f "$PROJECT_DIR/.env.example" ] && cp "$PROJECT_DIR/.env.example" "$package_dir/config/"
    
    # Create deployment scripts
    create_deployment_scripts "$package_dir" "$target"
    
    # Create README for deployment
    create_deployment_readme "$package_dir" "$target"
    
    # Create tarball
    cd "$DIST_DIR"
    tar -czf "${APP_NAME}-${target}.tar.gz" "${APP_NAME}-${target}"
    
    ok "Created deployment package: ${APP_NAME}-${target}.tar.gz"
}

create_deployment_scripts() {
    local package_dir=$1
    local target=$2
    
    # Create install script
    cat > "$package_dir/install.sh" <<'INSTALL_SCRIPT'
#!/bin/bash

set -euo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC} $*"; }

INSTALL_DIR="/opt/flow-frame"
SERVICE_NAME="flow-frame"
SERVICE_USER="flowframe"

install_dependencies() {
    info "Installing runtime dependencies"
    
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        sudo apt-get update -y
        sudo apt-get install -y \
            libsdl2-2.0-0 libsdl2-ttf-2.0-0 \
            ffmpeg libdrm2 libgl1-mesa-dri \
            libwayland-client0 libwayland-egl1-mesa \
            awscli
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y \
            SDL2 SDL2_ttf ffmpeg libdrm mesa-libGL awscli
    else
        warn "Unknown package manager. Please install SDL2, FFmpeg, and AWS CLI manually."
    fi
    
    ok "Dependencies installed"
}

create_service_user() {
    if id "$SERVICE_USER" >/dev/null 2>&1; then
        ok "Service user '$SERVICE_USER' exists"
    else
        info "Creating service user '$SERVICE_USER'"
        sudo useradd -r -s /usr/sbin/nologin -d "$INSTALL_DIR" "$SERVICE_USER" || \
        sudo adduser --system --no-create-home "$SERVICE_USER" || true
    fi
    
    # Add to required groups
    sudo usermod -aG video "$SERVICE_USER" 2>/dev/null || true
    sudo usermod -aG render "$SERVICE_USER" 2>/dev/null || true
    sudo usermod -aG input "$SERVICE_USER" 2>/dev/null || true
}

install_application() {
    info "Installing Flow Frame to $INSTALL_DIR"
    
    # Create install directory
    sudo mkdir -p "$INSTALL_DIR"
    
    # Copy files
    sudo cp -r bin assets config "$INSTALL_DIR/"
    
    # Set ownership and permissions
    sudo chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR"
    sudo chmod 755 "$INSTALL_DIR/bin/flow-frame"
    
    ok "Application installed"
}

create_systemd_service() {
    info "Creating systemd service"
    
    sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null <<SERVICE
[Unit]
Description=Flow Frame
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
SupplementaryGroups=video render input
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/bin/flow-frame
Restart=always
RestartSec=5
Environment=DISPLAY=:0
Environment=SDL_VIDEODRIVER=kmsdrm
EnvironmentFile=-$INSTALL_DIR/config/.env
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE
    
    sudo systemctl daemon-reload
    sudo systemctl enable $SERVICE_NAME
    
    ok "Service created and enabled"
}

main() {
    info "Installing Flow Frame"
    install_dependencies
    create_service_user
    install_application
    create_systemd_service
    
    info "Installation complete!"
    info "To start the service: sudo systemctl start $SERVICE_NAME"
    info "To view logs: sudo journalctl -u $SERVICE_NAME -f"
}

main "$@"
INSTALL_SCRIPT
    
    chmod +x "$package_dir/install.sh"
    
    # Create uninstall script
    cat > "$package_dir/uninstall.sh" <<'UNINSTALL_SCRIPT'
#!/bin/bash

set -euo pipefail

SERVICE_NAME="flow-frame"
INSTALL_DIR="/opt/flow-frame"
SERVICE_USER="flowframe"

info() { echo -e "\033[0;34m[INFO]\033[0m $*"; }
ok() { echo -e "\033[0;32m[OK]\033[0m $*"; }

info "Uninstalling Flow Frame"

# Stop and disable service
sudo systemctl stop $SERVICE_NAME 2>/dev/null || true
sudo systemctl disable $SERVICE_NAME 2>/dev/null || true
sudo rm -f /etc/systemd/system/$SERVICE_NAME.service
sudo systemctl daemon-reload

# Remove installation directory
sudo rm -rf "$INSTALL_DIR"

# Optionally remove service user
read -p "Remove service user '$SERVICE_USER'? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    sudo userdel "$SERVICE_USER" 2>/dev/null || true
    ok "Service user removed"
fi

ok "Flow Frame uninstalled"
UNINSTALL_SCRIPT
    
    chmod +x "$package_dir/uninstall.sh"
}

create_deployment_readme() {
    local package_dir=$1
    local target=$2
    
    cat > "$package_dir/README.md" <<README
# Flow Frame - Deployment Package

This package contains a pre-built Flow Frame executable for **${target}**.

## Contents

- \`bin/flow-frame\` - The main executable
- \`assets/\` - Application assets (videos, images, etc.)
- \`config/\` - Configuration files
- \`install.sh\` - Automated installation script
- \`uninstall.sh\` - Removal script

## Quick Installation

1. Extract the package:
   \`\`\`bash
   tar -xzf flow-frame-${target}.tar.gz
   cd flow-frame-${target}
   \`\`\`

2. Run the installation script:
   \`\`\`bash
   sudo ./install.sh
   \`\`\`

3. Start the service:
   \`\`\`bash
   sudo systemctl start flow-frame
   \`\`\`

## Manual Installation

If you prefer manual installation:

1. Install runtime dependencies:
   - SDL2 and SDL2_ttf
   - FFmpeg
   - Mesa/DRM drivers
   - AWS CLI (if using S3 features)

2. Copy the binary to your preferred location:
   \`\`\`bash
   sudo cp bin/flow-frame /usr/local/bin/
   \`\`\`

3. Copy assets and config as needed

## Configuration

- Copy \`config/.env.example\` to \`config/.env\` and customize
- Modify \`config/settings.json\` for application settings
- Ensure the service user has access to video/render/input groups

## System Requirements

- **Architecture**: ${target}
- **OS**: Debian/Ubuntu or compatible Linux distribution
- **Graphics**: DirectRM/KMS support recommended for best performance
- **Memory**: At least 256MB available RAM

## Troubleshooting

View service logs:
\`\`\`bash
sudo journalctl -u flow-frame -f
\`\`\`

Check service status:
\`\`\`bash
sudo systemctl status flow-frame
\`\`\`

## Support

For issues and support, refer to the main Flow Frame repository.
README
}

build_docker_image() {
    info "Using existing Dockerfile from project root"
    
    # The root Dockerfile is already comprehensive and includes all necessary dependencies
    # No need to create a new one
}

build_with_docker() {
    local target=$1
    
    info "Building $target using Docker"
    
    # Build Docker image using root Dockerfile
    docker build -t flow-frame-builder "$PROJECT_DIR"
    
    # Run build in container with output to dist directory
    docker run --rm \
        -v "$BUILD_DIR:/app/dist" \
        flow-frame-builder "$target" "/app/dist"
    
    ok "Docker build for $target completed"
}

show_usage() {
    cat <<USAGE
Usage: $0 [OPTIONS] [TARGETS...]

Build Flow Frame executables for Debian/Linux targets.

OPTIONS:
    -h, --help          Show this help message
    -c, --clean         Clean build directories before building
    -d, --docker        Use Docker for cross-compilation
    --install-deps      Install cross-compilation dependencies
    --list-targets      List available build targets

TARGETS:
    linux-arm64         64-bit ARM Linux (Radxa Zero)
    all                 Build for all targets

Examples:
    $0                          # Build for Radxa Zero (ARM64)
    $0 linux-arm64              # Build for ARM64 (Radxa Zero)
    $0 --docker linux-arm64     # Build for Radxa Zero using Docker
    $0 --clean linux-arm64      # Clean and build for Radxa Zero

USAGE
}

main() {
    local targets=()
    local use_docker=false
    local clean_build=false
    local install_deps=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -c|--clean)
                clean_build=true
                shift
                ;;
            -d|--docker)
                use_docker=true
                shift
                ;;
            --install-deps)
                install_deps=true
                shift
                ;;
            --list-targets)
                info "Available targets:"
                for entry in "${TARGETS[@]}"; do
                    local target="${entry%%:*}"
                    local arch="${entry##*:}"
                    echo "  $target ($arch)"
                done
                exit 0
                ;;
            all)
                targets=($(get_all_targets))
                shift
                ;;
            linux-*)
                if is_valid_target "$1"; then
                    targets+=("$1")
                else
                    err "Unknown target: $1"
                    exit 1
                fi
                shift
                ;;
            *)
                err "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Default to Radxa Zero (ARM64) target if no targets specified
    if [[ ${#targets[@]} -eq 0 ]]; then
        targets=("linux-arm64")
    fi
    
    info "Flow Frame Cross-Compilation Build Script"
    info "Targets: ${targets[*]}"
    
    # Clean if requested
    if [[ "$clean_build" == true ]]; then
        cleanup
    fi
    
    # Install dependencies if requested
    if [[ "$install_deps" == true ]]; then
        install_cross_compilers
    fi
    
    # Prepare build environment
    prepare_build_env
    
    # Set up Docker if requested
    if [[ "$use_docker" == true ]]; then
        build_docker_image
    fi
    
    # Build for each target
    local failed_targets=()
    for target in "${targets[@]}"; do
        info "Building target: $target"
        
        if [[ "$use_docker" == true ]]; then
            if build_with_docker "$target"; then
                create_deployment_package "$target"
            else
                failed_targets+=("$target")
            fi
        else
            if build_for_target "$target"; then
                create_deployment_package "$target"
            else
                failed_targets+=("$target")
            fi
        fi
    done
    
    # Report results
    info "Build Summary:"
    for target in "${targets[@]}"; do
        if [[ ${#failed_targets[@]} -gt 0 ]] && [[ " ${failed_targets[*]} " =~ " ${target} " ]]; then
            err "  $target: FAILED"
        else
            ok "  $target: SUCCESS"
            if [[ -f "$DIST_DIR/${APP_NAME}-${target}.tar.gz" ]]; then
                local size=$(du -h "$DIST_DIR/${APP_NAME}-${target}.tar.gz" | cut -f1)
                info "    Package: ${APP_NAME}-${target}.tar.gz ($size)"
            fi
        fi
    done
    
    if [[ ${#failed_targets[@]} -eq 0 ]]; then
        ok "All builds completed successfully!"
        info "Deployment packages are in: $DIST_DIR"
    else
        err "Some builds failed: ${failed_targets[*]}"
        exit 1
    fi
}

main "$@"
