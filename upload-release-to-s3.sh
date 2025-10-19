#!/bin/bash

set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
BUCKET_NAME="flow-frame-releases"
BINARY_NAME="flow-frame"
BUILD_GOOS="linux"
BUILD_GOARCH="arm64"

# Function to print colored messages
print_info() {
    echo -e "${GREEN}$1${NC}"
}

print_warn() {
    echo -e "${YELLOW}$1${NC}"
}

print_error() {
    echo -e "${RED}$1${NC}"
}

# Check if required commands are available
check_dependencies() {
    if ! command -v aws &> /dev/null; then
        print_error "Error: AWS CLI is not installed or not in PATH"
        exit 1
    fi

    if ! command -v go &> /dev/null; then
        print_error "Error: Go is not installed or not in PATH"
        exit 1
    fi

    print_info "Dependencies check passed: AWS CLI and Go are available"
}

# Get the next version number
get_next_version() {
    # List all folders in the bucket (they end with /)
    local versions=$(aws s3 ls "s3://${BUCKET_NAME}/" 2>/dev/null | grep "PRE" | awk '{print $2}' | sed 's/\///g')

    if [ -z "$versions" ]; then
        # No versions exist, start with 1.0
        echo "1.0"
        return
    fi

    # Find the highest version
    local max_major=0
    local max_minor=0

    while IFS= read -r version; do
        # Handle both "1" and "1.0" formats
        if [[ "$version" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
            # Format: X.Y
            local major="${BASH_REMATCH[1]}"
            local minor="${BASH_REMATCH[2]}"
        elif [[ "$version" =~ ^([0-9]+)$ ]]; then
            # Format: X (treat as X.0)
            local major="${BASH_REMATCH[1]}"
            local minor=0
        else
            # Invalid format, skip
            continue
        fi

        # Update max if this version is higher
        if [ "$major" -gt "$max_major" ]; then
            max_major="$major"
            max_minor="$minor"
        elif [ "$major" -eq "$max_major" ] && [ "$minor" -gt "$max_minor" ]; then
            max_minor="$minor"
        fi
    done <<< "$versions"

    # Print status to stderr (so it doesn't interfere with the return value)
    >&2 print_info "Current latest version: ${max_major}.${max_minor}"

    # Calculate next version
    if [ "$max_minor" -ge 9 ]; then
        # Increment major, reset minor to 0
        local next_major=$((max_major + 1))
        local next_minor=0
    else
        # Increment minor
        local next_major=$max_major
        local next_minor=$((max_minor + 1))
    fi

    # Return only the version number to stdout
    echo "${next_major}.${next_minor}"
}

# Build the Go binary
build_binary() {
    local version=$1

    print_info "Building version: ${version}"
    print_info "Building Go binary for ${BUILD_GOARCH} ${BUILD_GOOS}..."

    # Check if we're cross-compiling from macOS to Linux
    if [ "$(uname)" == "Darwin" ] && [ "${BUILD_GOOS}" == "linux" ]; then
        print_warn "WARNING: Cross-compiling from macOS to Linux with CGO is complex"
        print_warn "This project uses SDL2 which requires CGO and platform-specific libraries"
        print_warn ""
        print_warn "Options:"
        print_warn "  1. Run this script on the target Linux ARM64 platform (recommended)"
        print_warn "  2. Use --skip-build flag and upload a pre-built binary"
        print_warn "  3. Set up a cross-compilation toolchain (advanced)"
        print_warn ""
        print_warn "Attempting build anyway - this may fail..."
        echo ""
    fi

    # Build the binary with proper environment variables
    # Note: CGO is required for SDL2, so we don't disable it
    GOOS="${BUILD_GOOS}" GOARCH="${BUILD_GOARCH}" go build -o "${BINARY_NAME}" .

    if [ ! -f "${BINARY_NAME}" ]; then
        print_error "Error: Build failed, binary not found"
        print_error ""
        print_error "To upload a pre-built binary, use: $0 --skip-build"
        print_error "Make sure you have a '${BINARY_NAME}' file in the current directory"
        exit 1
    fi

    local size=$(ls -lh "${BINARY_NAME}" | awk '{print $5}')
    print_info "Build successful: ${BINARY_NAME} (${size})"
}

# Upload binary to S3
upload_to_s3() {
    local version=$1
    local s3_path="s3://${BUCKET_NAME}/${version}/${BINARY_NAME}"

    print_info "Uploading to ${s3_path}..."

    # Upload the binary
    aws s3 cp "${BINARY_NAME}" "${s3_path}"

    if [ $? -eq 0 ]; then
        print_info "Upload complete!"
        print_info "Binary available at: ${s3_path}"
    else
        print_error "Error: Upload failed"
        exit 1
    fi
}

# Clean up build artifacts
cleanup() {
    if [ -f "${BINARY_NAME}" ]; then
        print_info "Cleaning up build artifacts..."
        rm -f "${BINARY_NAME}"
    fi
}

# Main execution
main() {
    # Parse command line arguments
    # Usage: ./upload-release-to-s3.sh [--skip-build]
    SKIP_BUILD=false
    if [ "$1" == "--skip-build" ]; then
        SKIP_BUILD=true
    fi

    print_info "=== Flow Frame Release Upload Script ==="
    echo ""

    # Check dependencies
    check_dependencies
    echo ""

    # Get next version
    print_info "Fetching existing versions from S3..."
    NEXT_VERSION=$(get_next_version)
    print_info "Next version will be: ${NEXT_VERSION}"
    echo ""

    # Build binary (unless --skip-build is specified)
    if [ "$SKIP_BUILD" = false ]; then
        build_binary "${NEXT_VERSION}"
        echo ""
    else
        print_warn "Skipping build - checking for existing binary..."
        if [ ! -f "${BINARY_NAME}" ]; then
            print_error "Error: Binary '${BINARY_NAME}' not found in current directory"
            print_error "Please build the binary first or remove --skip-build flag"
            exit 1
        fi
        local size=$(ls -lh "${BINARY_NAME}" | awk '{print $5}')
        print_info "Found existing binary: ${BINARY_NAME} (${size})"
        print_info "Building version: ${NEXT_VERSION}"
        echo ""
    fi

    # Upload to S3
    upload_to_s3 "${NEXT_VERSION}"
    echo ""

    # Cleanup (only if we built the binary)
    if [ "$SKIP_BUILD" = false ]; then
        cleanup
    else
        print_info "Keeping binary (not built by this script)"
    fi

    print_info "=== Release ${NEXT_VERSION} Complete ==="
}

# Run main function with all arguments
main "$@"
