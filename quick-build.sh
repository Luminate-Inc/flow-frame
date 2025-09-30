#!/bin/bash

set -euo pipefail

# Quick build script for Flow Frame
# Builds for the current platform without cross-compilation complexity

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
APP_NAME="flow-frame"

main() {
    info "Quick build for Flow Frame"
    
    cd "$PROJECT_DIR"
    
    # Check if Go is installed
    if ! command -v go >/dev/null 2>&1; then
        err "Go is not installed. Please install Go 1.23.1 or later."
        exit 1
    fi
    
    # Show Go version
    GO_VERSION=$(go version | sed -n 's/.*go\([0-9][^ ]*\).*/\1/p')
    info "Using Go version: $GO_VERSION"
    
    # Download dependencies
    info "Downloading dependencies..."
    go mod download
    go mod tidy
    
    # Build for current platform
    info "Building for current platform..."
    
    export CGO_ENABLED=1
    
    BUILD_FLAGS=(
        -v
        -ldflags "-s -w"
        -trimpath
    )
    
    if go build "${BUILD_FLAGS[@]}" -o "$APP_NAME" .; then
        ok "Build successful!"
        
        # Show file info
        local size=$(du -h "$APP_NAME" | cut -f1)
        info "Executable: $PROJECT_DIR/$APP_NAME ($size)"
        
        # Make executable
        chmod +x "$APP_NAME"
        
        # Test the binary
        if ./"$APP_NAME" --help >/dev/null 2>&1 || [ $? -eq 1 ]; then
            ok "Binary appears to be working"
        else
            warn "Binary might have issues (this could be normal for GUI apps)"
        fi
        
        info "You can now run: ./$APP_NAME"
        
    else
        err "Build failed"
        exit 1
    fi
}

main "$@"
