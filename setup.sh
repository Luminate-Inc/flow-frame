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
    install_packages
    install_go
    build_app
    ensure_service_user
    configure_gpu_permissions
    minimal_display_check
    deploy_to_install_dir
    create_systemd_service

    info "Recent logs:"
    sudo journalctl -u "$SERVICE_NAME" -n 20 --no-pager || true
    ok "Setup complete"
}

main "$@"
