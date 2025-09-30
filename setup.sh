#!/bin/bash

set -euo pipefail

# Minimal, idempotent setup for headless systems
# - Installs essential packages
# - Installs Go
# - Builds the app
# - Sets GPU/display permissions for no-desktop environments
# - Installs a systemd service that runs update wrapper before the app and restarts on failure

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC} $*"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="flow-frame"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SERVICE_USER="${SERVICE_USER:-flowframe}"
GO_VERSION="1.23.1"
INSTALL_DIR="/opt/flow-frame"

# Detect basic platform details
OS_ID="$(. /etc/os-release 2>/dev/null && echo "$ID" || echo "unknown")"
OS_VERSION_ID="$(. /etc/os-release 2>/dev/null && echo "$VERSION_ID" || echo "")"
MACHINE_ARCH="$(uname -m)"

is_debian_like() {
    case "$OS_ID" in
        debian|raspbian|ubuntu) return 0 ;;
        *) return 1 ;;
    esac
}

is_radxa_zero() {
    # Heuristics based on device tree compatible or model strings
    if [ -r /proc/device-tree/compatible ] && grep -aiq "radxa,zero" /proc/device-tree/compatible 2>/dev/null; then
        return 0
    fi
    if [ -r /proc/device-tree/model ] && grep -aiq "Radxa Zero" /proc/device-tree/model 2>/dev/null; then
        return 0
    fi
    if [ -r /sys/firmware/devicetree/base/compatible ] && grep -aiq "radxa,zero" /sys/firmware/devicetree/base/compatible 2>/dev/null; then
        return 0
    fi
    return 1
}

detect_pm() {
    if command -v apt-get >/dev/null 2>&1; then echo apt; return; fi
    if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
    if command -v pacman >/dev/null 2>&1; then echo pacman; return; fi
    echo unknown
}

install_packages() {
    local pm=$(detect_pm)
    info "Installing essential packages (package manager: $pm)"
    case "$pm" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            sudo apt-get update -y
            sudo apt-get install -y \
                ca-certificates curl wget git pkg-config build-essential python3 awscli \
                ffmpeg libdrm2 libgl1-mesa-dri libwayland-client0 libwayland-egl1-mesa \
                libsdl2-2.0-0 libsdl2-ttf-2.0-0 libsdl2-dev libsdl2-ttf-dev \
                libavcodec-dev libavformat-dev libavutil-dev libswscale-dev
            ;;
        dnf)
            sudo dnf install -y \
                ca-certificates curl wget git pkgconf-pkg-config @"Development Tools" python3 awscli \
                ffmpeg ffmpeg-devel libdrm mesa-libGL \
                SDL2 SDL2_ttf SDL2-devel SDL2_ttf-devel
            ;;
        pacman)
            sudo pacman -Syu --noconfirm
            sudo pacman -S --noconfirm \
                ca-certificates curl wget git pkgconf base-devel python ffmpeg mesa libdrm \
                sdl2 sdl2_ttf aws-cli
            ;;
        *)
            warn "Unknown package manager. Please install build tools, ffmpeg dev libs, SDL2, awscli manually."
            ;;
    esac
    ok "Packages installed"
}

ensure_debian_nonfree_firmware() {
    # Ensure non-free-firmware enabled on Debian 12+ for wifi/BT blobs
    if ! is_debian_like; then return; fi
    if [ ! -r /etc/apt/sources.list ]; then return; fi
    if grep -Eq "^deb .* (bookworm|trixie|sid) main" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
        if ! grep -Eq "non-free-firmware" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
            info "Enabling non-free-firmware component"
            sudo sed -i -E 's/^(deb .* (bookworm|trixie|sid) .* main.*)$/\1 non-free-firmware/' /etc/apt/sources.list || true
            sudo sed -i -E 's/^(deb-src .* (bookworm|trixie|sid) .* main.*)$/\1 non-free-firmware/' /etc/apt/sources.list || true
            sudo apt-get update -y || true
        fi
    else
        # For older Debian, ensure non-free is present
        if ! grep -Eq " non-free" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
            info "Enabling contrib non-free components"
            sudo sed -i -E 's/^(deb .* main)$/\1 contrib non-free/' /etc/apt/sources.list || true
            sudo sed -i -E 's/^(deb-src .* main)$/\1 contrib non-free/' /etc/apt/sources.list || true
            sudo apt-get update -y || true
        fi
    fi
}

install_radxa_zero_wifi_bt() {
    if ! is_debian_like; then return; fi
    if ! is_radxa_zero; then return; fi
    info "Installing Radxa Zero Wi-Fi/Bluetooth firmware and tools"
    export DEBIAN_FRONTEND=noninteractive
    # Broadcom/CYW43455/43430 commonly used on Zero variants
    sudo apt-get install -y firmware-brcm80211 bluez rfkill crda iw wpasupplicant || true
    # Ensure BT service enabled
    sudo systemctl enable bluetooth 2>/dev/null || true
    sudo systemctl restart bluetooth 2>/dev/null || true
    # Unblock radios
    rfkill unblock all 2>/dev/null || true
    ok "Wi-Fi/Bluetooth components installed"
}

install_radxa_zero_gpu_video() {
    if ! is_debian_like; then return; fi
    if ! is_radxa_zero; then return; fi
    info "Installing GPU (Mesa/Panfrost) and video acceleration tools"
    export DEBIAN_FRONTEND=noninteractive
    # Panfrost for Mali-G31, GBM/KMS, Vulkan userspace
    sudo apt-get install -y \
        mesa-vulkan-drivers mesa-vulkan-drivers:arm64 2>/dev/null || true
    sudo apt-get install -y \
        mesa-utils mesa-utils-extra libgl1-mesa-dri libgles2 \
        libvulkan1 vulkan-tools || true
    # V4L2 and ffmpeg hw accel helpers (userspace)
    sudo apt-get install -y v4l-utils || true
    # Kernel extra modules (if repository provides) for multimedia
    if apt-cache show linux-modules-extra-$(uname -r) >/dev/null 2>&1; then
        sudo apt-get install -y linux-modules-extra-$(uname -r) || true
    fi
    ok "GPU/Video components installed"
}

radxa_zero_diagnostics() {
    if ! is_radxa_zero; then return; fi
    info "Radxa Zero diagnostics"
    if [ -r /proc/device-tree/model ]; then
        cat /proc/device-tree/model | tr -d '\0' | sed 's/^/  /'
    fi
    info "Wi-Fi firmware present?"
    ls -1 /lib/firmware/brcm/brcmfmac* 2>/dev/null | sed 's/^/  /' || true
    info "DRM devices:"
    if [ -d /dev/dri ]; then ls -la /dev/dri | sed 's/^/  /'; fi
    info "Vulkan ICDs:"
    ls -la /usr/share/vulkan/icd.d 2>/dev/null | sed 's/^/  /' || true
}

install_go() {
    local arch
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l) arch="armv6l" ;;
        *) err "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac

    if command_exists go; then
        local ver=$(go version | sed -n 's/.*go\([0-9][^ ]*\).*/\1/p')
        if [ "$ver" = "$GO_VERSION" ]; then ok "Go $GO_VERSION already installed"; return; fi
        warn "Found Go $ver, upgrading to $GO_VERSION"
    fi

    local tgz="go${GO_VERSION}.linux-${arch}.tar.gz"
    local url="https://go.dev/dl/${tgz}"
    info "Downloading Go $GO_VERSION ($arch)"
    curl -fsSL "$url" -o "/tmp/${tgz}"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "/tmp/${tgz}"
    rm -f "/tmp/${tgz}"

    if ! echo "$PATH" | grep -q "/usr/local/go/bin"; then
        echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee -a /etc/profile.d/go-path.sh >/dev/null
        export PATH=$PATH:/usr/local/go/bin
    fi
    ok "Go $GO_VERSION installed"
}

build_app() {
    info "Building application"
    cd "$PROJECT_DIR"
    export CGO_ENABLED=1
    go mod download
    go build -v -o "$PROJECT_DIR/flow-frame" .
    chmod 755 "$PROJECT_DIR/flow-frame"
    ok "Build complete: $PROJECT_DIR/flow-frame"
}

ensure_service_user() {
    if id "$SERVICE_USER" >/dev/null 2>&1; then
        ok "Service user '$SERVICE_USER' exists"
    else
        info "Creating service user '$SERVICE_USER'"
        sudo useradd -r -s /usr/sbin/nologin -d "$PROJECT_DIR" "$SERVICE_USER" || sudo adduser --system --no-create-home "$SERVICE_USER" || true
    fi
    sudo usermod -aG video "$SERVICE_USER" 2>/dev/null || true
    sudo usermod -aG render "$SERVICE_USER" 2>/dev/null || true
    sudo usermod -aG input "$SERVICE_USER" 2>/dev/null || true
}

deploy_to_install_dir() {
    info "Deploying application to $INSTALL_DIR"
    # Stop existing service to avoid file-in-use issues
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true

    # Create install directory and sync contents
    sudo mkdir -p "$INSTALL_DIR"
    sudo rsync -a --delete "$PROJECT_DIR"/ "$INSTALL_DIR"/

    # Ensure correct ownership
    sudo chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR"

    # Secure permissions (dirs 755, files 644), then mark executables
    sudo find "$INSTALL_DIR" -type d -exec chmod 0755 {} \;
    sudo find "$INSTALL_DIR" -type f -exec chmod 0644 {} \;
    sudo chmod 0755 "$INSTALL_DIR/flow-frame" 2>/dev/null || true
    sudo chmod 0755 "$INSTALL_DIR/check-updates-wrapper.sh" 2>/dev/null || true
    sudo chmod 0755 "$INSTALL_DIR/update.sh" 2>/dev/null || true

    # Environment file readability for service user
    if [ -f "$INSTALL_DIR/.env" ]; then
        sudo chown "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR/.env" || true
        sudo chmod 0640 "$INSTALL_DIR/.env" || true
    fi

    ok "Deployed to $INSTALL_DIR"
}

configure_gpu_permissions() {
    info "Configuring GPU/display device permissions (udev)"
    local rules="/etc/udev/rules.d/99-${SERVICE_NAME}-gpu.rules"
    sudo bash -c "cat > '$rules'" <<'RULES'
SUBSYSTEM=="drm", KERNEL=="card*", GROUP="video", MODE="0660"
SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0660"
SUBSYSTEM=="graphics", KERNEL=="fb0", GROUP="video", MODE="0660"
RULES
    sudo udevadm control --reload-rules || true
    sudo udevadm trigger || true
    ok "GPU/display permissions configured"
}

create_systemd_service() {
    info "Installing systemd service: $SERVICE_NAME"
    local exec_pre="$INSTALL_DIR/check-updates-wrapper.sh"
    local exec_start="$INSTALL_DIR/flow-frame"

    if [ ! -x "$exec_pre" ]; then chmod +x "$exec_pre" || true; fi
    if [ ! -x "$exec_start" ]; then err "Executable missing: $exec_start"; exit 1; fi

    sudo bash -c "cat > '$SERVICE_FILE'" <<SERVICE
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
ExecStartPre=$exec_pre
ExecStart=$exec_start
Restart=always
RestartSec=5
Environment=DISPLAY=:0
Environment=SDL_VIDEODRIVER=kmsdrm
EnvironmentFile=$INSTALL_DIR/.env
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    sudo systemctl restart "$SERVICE_NAME" || sudo systemctl start "$SERVICE_NAME"
    ok "Service enabled and started"
}

minimal_display_check() {
    info "Display/GPU check (non-fatal)"
    if [ -d /dev/dri ]; then ls -la /dev/dri | sed 's/^/  /'; else warn "/dev/dri not present"; fi
    if [ -c /dev/fb0 ]; then ls -la /dev/fb0 | sed 's/^/  /'; else info "/dev/fb0 not present (OK if using KMS/DRM)"; fi
}

main() {
    info "Starting minimal setup in $PROJECT_DIR"
    ensure_debian_nonfree_firmware
    install_packages
    install_go
    build_app
    ensure_service_user
    install_radxa_zero_wifi_bt
    install_radxa_zero_gpu_video
    configure_gpu_permissions
    minimal_display_check
    radxa_zero_diagnostics
    deploy_to_install_dir
    create_systemd_service

    info "Recent logs:"
    sudo journalctl -u "$SERVICE_NAME" -n 20 --no-pager || true
    ok "Setup complete"
}

main "$@"
