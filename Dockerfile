FROM golang:1.23.1-bullseye

# Install cross-compilation toolchains and all dependencies
RUN apt-get update && apt-get install -y \
    gcc-x86-64-linux-gnu \
    gcc-aarch64-linux-gnu \
    gcc-arm-linux-gnueabihf \
    pkg-config \
    libsdl2-dev \
    libsdl2-ttf-dev \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswscale-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy go mod files first for better caching
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build script that handles multiple targets
RUN cat > /usr/local/bin/build-target << 'EOF'
#!/bin/bash
set -euo pipefail

TARGET=${1:-linux-amd64}
OUTPUT_DIR=${2:-/app/dist}

echo "Building Flow Frame for $TARGET..."

case "$TARGET" in
    "linux-amd64")
        export CC=x86_64-linux-gnu-gcc
        export GOARCH=amd64
        export PKG_CONFIG_PATH=/usr/lib/x86_64-linux-gnu/pkgconfig
        ;;
    "linux-arm64")
        export CC=aarch64-linux-gnu-gcc
        export GOARCH=arm64
        export PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig
        ;;
    "linux-armv7")
        export CC=arm-linux-gnueabihf-gcc
        export GOARCH=arm
        export GOARM=7
        export PKG_CONFIG_PATH=/usr/lib/arm-linux-gnueabihf/pkgconfig
        ;;
    "linux-armv6")
        export CC=arm-linux-gnueabihf-gcc
        export GOARCH=arm
        export GOARM=6
        export PKG_CONFIG_PATH=/usr/lib/arm-linux-gnueabihf/pkgconfig
        ;;
    *)
        echo "Unsupported target: $TARGET"
        exit 1
        ;;
esac

export GOOS=linux
export CGO_ENABLED=1

# Build flags for optimized, portable binary
BUILD_FLAGS=(
    -v
    -ldflags "-s -w -extldflags '-static-libgcc'"
    -trimpath
)

mkdir -p "$OUTPUT_DIR"

# Build the executable
if go build "${BUILD_FLAGS[@]}" -o "$OUTPUT_DIR/flow-frame-$TARGET" .; then
    echo "✅ Built flow-frame-$TARGET successfully"
    
    # Show file info
    ls -lh "$OUTPUT_DIR/flow-frame-$TARGET"
    file "$OUTPUT_DIR/flow-frame-$TARGET"
else
    echo "❌ Build failed for $TARGET"
    exit 1
fi
EOF

RUN chmod +x /usr/local/bin/build-target

ENTRYPOINT ["/usr/local/bin/build-target"]
