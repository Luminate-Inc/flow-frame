#!/bin/bash

# Art Frame Auto-Update Script
# This script checks AWS S3 for codebase updates and applies them if available
#
# Usage:
#   ./update.sh [--force] [--check-only] [--backup-dir=path]
#
# Environment Variables (Required):
#   ART_FRAME_S3_BUCKET   - S3 bucket name containing the codebase
#   AWS_ACCESS_KEY_ID     - AWS access key
#   AWS_SECRET_ACCESS_KEY - AWS secret key
#   AWS_DEFAULT_REGION    - AWS region (default: us-east-1)
#
# Optional Environment Variables:
#   ART_FRAME_UPDATE_LOG  - Log file location (default: /var/log/art-frame-update.log)
#   ART_FRAME_BACKUP_DIR  - Backup directory (default: /var/backups/art-frame)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
PROJECT_DIR="$(pwd)"
TEMP_DIR="/tmp/art-frame-update"
VERSION_FILE="$PROJECT_DIR/.current_version"
LOG_FILE="${ART_FRAME_UPDATE_LOG:-/var/log/art-frame-update.log}"
BACKUP_DIR="${ART_FRAME_BACKUP_DIR:-/var/backups/art-frame}"
FORCE_UPDATE=false
CHECK_ONLY=false

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "$message"
    
    # Also log to file if we have write permission
    if [ -w "$(dirname "$LOG_FILE")" ] 2>/dev/null || [ -w "$LOG_FILE" ] 2>/dev/null; then
        echo "[$timestamp] [$level] $message" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
    fi
}

print_status() {
    log "INFO" "${BLUE}[INFO]${NC} $1"
}

print_success() {
    log "SUCCESS" "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    log "WARNING" "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    log "ERROR" "${RED}[ERROR]${NC} $1"
}

# Function to ensure Go is available
ensure_go_available() {
    # First check if go is in PATH
    if command -v go >/dev/null 2>&1; then
        print_status "Go found in PATH: $(which go)"
        return 0
    fi
    
    # Try adding common Go installation paths
    local go_paths=(
        "/usr/local/go/bin"
        "/usr/bin"
        "/opt/go/bin"
        "$HOME/go/bin"
    )
    
    for go_path in "${go_paths[@]}"; do
        if [ -x "$go_path/go" ]; then
            print_status "Found Go at $go_path/go, adding to PATH"
            export PATH="$go_path:$PATH"
            return 0
        fi
    done
    
    return 1
}

# Function to run command with timeout (fallback if timeout command not available)
run_with_timeout() {
    local timeout_seconds="$1"
    shift
    local cmd="$*"
    
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_seconds" $cmd
    else
        # Fallback: run without timeout if timeout command not available
        print_warning "timeout command not available, running without timeout"
        $cmd
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_UPDATE=true
            shift
            ;;
        --check-only)
            CHECK_ONLY=true
            shift
            ;;
        --backup-dir=*)
            BACKUP_DIR="${1#*=}"
            shift
            ;;
        --help)
            echo "Usage: $0 [--force] [--check-only] [--backup-dir=path]"
            echo "  --force         Force update even if version hasn't changed"
            echo "  --check-only    Only check for updates, don't apply them"
            echo "  --backup-dir    Custom backup directory"
            echo "  --help          Show this help message"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

print_status "Art Frame Update Check Starting..."
print_status "Project Directory: $PROJECT_DIR"
print_status "Log File: $LOG_FILE"
print_status "Backup Directory: $BACKUP_DIR"

# Check required environment variables
if [ -z "$ART_FRAME_S3_BUCKET" ]; then
    print_error "ART_FRAME_S3_BUCKET environment variable is required"
    print_status "Set it with: export ART_FRAME_S3_BUCKET='your-bucket-name'"
    exit 1
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is not installed. Please install it first:"
    echo "  Ubuntu/Debian: sudo apt-get install awscli"
    echo "  CentOS/RHEL: sudo yum install awscli"
    echo "  Or: pip install awscli"
    exit 1
fi

# Verify AWS credentials
print_status "Checking AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS credentials not configured. Please set environment variables:"
    echo "  export AWS_ACCESS_KEY_ID='your_access_key'"
    echo "  export AWS_SECRET_ACCESS_KEY='your_secret_key'"
    echo "  export AWS_DEFAULT_REGION='us-east-1'"
    exit 1
fi

# Check if Go is available (required for building)
print_status "Checking Go availability..."
if ! ensure_go_available; then
    print_error "Go is not installed or not accessible"
    print_error "Please run setup.sh first to install Go: sudo ./setup.sh"
    exit 1
fi

# Note about systemd timeout
print_status "Note: If running as systemd service, ensure TimeoutStartSec is set to at least 900 seconds"
print_status "to allow sufficient time for Go dependency download and build on Raspberry Pi"

# Get current local version
CURRENT_VERSION=""
if [ -f "$VERSION_FILE" ]; then
    CURRENT_VERSION=$(cat "$VERSION_FILE" | tr -d '\n\r' | sed 's/[[:space:]]*$//')
    print_status "Current local version: $CURRENT_VERSION"
else
    print_warning "No version file found. This appears to be a fresh installation."
    CURRENT_VERSION=""
fi

# Check for latest version in S3
print_status "Checking for latest version in S3..."
LATEST_METADATA_FILE="$TEMP_DIR/latest.json"

# Create temp directory
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# Download latest metadata
if ! aws s3 cp "s3://$ART_FRAME_S3_BUCKET/latest.json" "$LATEST_METADATA_FILE" 2>/dev/null; then
    print_error "Failed to download latest version metadata from S3"
    print_status "Make sure the bucket exists and contains uploaded codebase"
    exit 1
fi

# Parse latest version info
if ! command -v python3 &> /dev/null; then
    print_error "Python3 is required for JSON parsing but not found"
    exit 1
fi

LATEST_VERSION=$(python3 -c "
import json
import sys
try:
    with open('$LATEST_METADATA_FILE', 'r') as f:
        data = json.load(f)
    print(data['version'])
except Exception as e:
    print('', file=sys.stderr)
    sys.exit(1)
")

if [ -z "$LATEST_VERSION" ]; then
    print_error "Failed to parse latest version from metadata"
    exit 1
fi

print_status "Latest S3 version: $LATEST_VERSION"

# Check if update is needed
UPDATE_NEEDED=false
if [ "$FORCE_UPDATE" = true ]; then
    print_status "Force update requested"
    UPDATE_NEEDED=true
elif [ -z "$CURRENT_VERSION" ]; then
    print_status "No current version found, update needed"
    UPDATE_NEEDED=true
elif [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
    print_status "Version mismatch, update needed"
    UPDATE_NEEDED=true
else
    print_success "Local version is up to date"
    UPDATE_NEEDED=false
fi

if [ "$CHECK_ONLY" = true ]; then
    if [ "$UPDATE_NEEDED" = true ]; then
        print_status "Update available: $CURRENT_VERSION -> $LATEST_VERSION"
        exit 2  # Exit code 2 indicates update available
    else
        print_success "No update needed"
        exit 0
    fi
fi

if [ "$UPDATE_NEEDED" = false ]; then
    print_success "No update needed. Exiting."
    rm -rf "$TEMP_DIR"
    exit 0
fi

# Perform update
print_status "Starting update process: $CURRENT_VERSION -> $LATEST_VERSION"

# Get archive info from metadata
ARCHIVE_NAME=$(python3 -c "
import json
with open('$LATEST_METADATA_FILE', 'r') as f:
    data = json.load(f)
print(data['archive_name'])
")

EXPECTED_SHA256=$(python3 -c "
import json
with open('$LATEST_METADATA_FILE', 'r') as f:
    data = json.load(f)
print(data['sha256_hash'])
")

print_status "Archive: $ARCHIVE_NAME"
print_status "Expected SHA256: $EXPECTED_SHA256"

# Download the archive
ARCHIVE_PATH="$TEMP_DIR/$ARCHIVE_NAME"
print_status "Downloading archive from S3..."
if ! aws s3 cp "s3://$ART_FRAME_S3_BUCKET/releases/$ARCHIVE_NAME" "$ARCHIVE_PATH"; then
    print_error "Failed to download archive from S3"
    exit 1
fi

# Verify archive integrity
print_status "Verifying archive integrity..."
ACTUAL_SHA256=$(sha256sum "$ARCHIVE_PATH" | cut -d' ' -f1)
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    print_error "Archive integrity check failed!"
    print_error "Expected: $EXPECTED_SHA256"
    print_error "Actual:   $ACTUAL_SHA256"
    exit 1
fi
print_success "Archive integrity verified"

# Create backup
print_status "Creating backup of current installation..."
mkdir -p "$BACKUP_DIR"
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="$BACKUP_DIR/art-frame-backup-$BACKUP_TIMESTAMP.tar.gz"

# Check if we're running as part of the service itself
if [ -n "$SYSTEMD_EXEC_PID" ] || [ "$$" = "$(pgrep -f 'art-frame.service' | head -1)" ]; then
    print_warning "Update script is running as part of the service - cannot stop service"
    print_status "Skipping service stop/restart - update will be applied on next restart"
    SERVICE_WAS_RUNNING=false
    SKIP_SERVICE_RESTART=true
else
    # Stop the service before update
    print_status "Stopping art-frame service..."
    if systemctl is-active --quiet art-frame 2>/dev/null; then
        sudo systemctl stop art-frame
        print_success "Service stopped"
        SERVICE_WAS_RUNNING=true
        SKIP_SERVICE_RESTART=false
    else
        print_status "Service was not running"
        SERVICE_WAS_RUNNING=false
        SKIP_SERVICE_RESTART=false
    fi
fi

# Create backup (excluding the binary)
tar --exclude='./art-frame' \
    --exclude='./.git' \
    --exclude='./tmp' \
    -czf "$BACKUP_PATH" \
    -C "$PROJECT_DIR" .

print_success "Backup created: $BACKUP_PATH"

# Extract new version
print_status "Extracting new version..."
EXTRACT_DIR="$TEMP_DIR/extract"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

# Copy new files (preserve certain local files)
print_status "Updating files..."
PRESERVE_FILES=".env settings.json .current_version"

# Move preserved files to temp location
for file in $PRESERVE_FILES; do
    if [ -f "$PROJECT_DIR/$file" ]; then
        cp "$PROJECT_DIR/$file" "$TEMP_DIR/preserve_$file" 2>/dev/null || true
    fi
done

# Remove old files (except preserved ones and the binary)
find "$PROJECT_DIR" -mindepth 1 -maxdepth 1 \
    ! -name "art-frame" \
    ! -name ".env" \
    ! -name "settings.json" \
    ! -name ".current_version" \
    ! -name ".git" \
    -exec rm -rf {} \;

# Copy new files
cp -r "$EXTRACT_DIR"/* "$PROJECT_DIR/"

# Restore preserved files
for file in $PRESERVE_FILES; do
    if [ -f "$TEMP_DIR/preserve_$file" ]; then
        cp "$TEMP_DIR/preserve_$file" "$PROJECT_DIR/$file"
        print_status "Preserved: $file"
    fi
done

# Update version file
echo "$LATEST_VERSION" > "$VERSION_FILE"
print_status "Updated version file"

# Build new binary
print_status "Building new binary..."

# Ensure Go is available
if ! ensure_go_available; then
    print_error "Go is not installed or not accessible"
    print_status "Attempting to restore from backup..."
    
    # Restore from backup
    tar -xzf "$BACKUP_PATH" -C "$PROJECT_DIR"
    
    print_error "Update failed. Go not available. Restored from backup."
    exit 1
fi

cd "$PROJECT_DIR"

# Ensure Go module is properly configured
print_status "Verifying Go module configuration..."
if [ ! -f "go.mod" ]; then
    print_error "go.mod file not found"
    print_status "Attempting to restore from backup..."
    tar -xzf "$BACKUP_PATH" -C "$PROJECT_DIR"
    print_error "Update failed. go.mod missing. Restored from backup."
    exit 1
fi

# Check if go.sum exists and is valid
if [ -f "go.sum" ]; then
    print_status "go.sum file found, verifying dependencies..."
    if run_with_timeout 60 go mod verify; then
        print_status "Dependencies verified, skipping download..."
    else
        print_status "Dependencies need to be downloaded..."
        # Download dependencies with timeout
        print_status "Downloading Go dependencies..."
        if ! run_with_timeout 300 go mod download; then
            print_error "Failed to download Go dependencies (timeout or error)"
            print_status "Attempting to restore from backup..."
            tar -xzf "$BACKUP_PATH" -C "$PROJECT_DIR"
            print_error "Update failed. Dependencies download failed. Restored from backup."
            exit 1
        fi
    fi
else
    print_status "go.sum not found, downloading dependencies..."
    # Download dependencies with timeout
    print_status "Downloading Go dependencies..."
    if ! run_with_timeout 300 go mod download; then
        print_error "Failed to download Go dependencies (timeout or error)"
        print_status "Attempting to restore from backup..."
        tar -xzf "$BACKUP_PATH" -C "$PROJECT_DIR"
        print_error "Update failed. Dependencies download failed. Restored from backup."
        exit 1
    fi
fi

# Build optimized for Raspberry Pi (no timeout)
print_status "Building binary (this may take a few minutes on Raspberry Pi)..."
print_status "Build started at: $(date)"

# Run build without timeout to prevent systemd timeout issues
# Use build cache and parallel compilation for better performance
print_status "Starting build with verbose output..."
if ! go build -v -ldflags="-s -w" -trimpath -o art-frame .; then
    print_error "Failed to build new binary!"
    print_status "Build failed at: $(date)"
    print_status "Attempting to restore from backup..."
    
    # Restore from backup
    tar -xzf "$BACKUP_PATH" -C "$PROJECT_DIR"
    
    print_error "Update failed. Restored from backup."
    exit 1
fi

print_status "Build completed at: $(date)"

print_success "Binary built successfully"

# Set proper permissions
chmod +x "$PROJECT_DIR/art-frame"

# Clean up
rm -rf "$TEMP_DIR"

print_success "Update completed successfully!"
print_status "Updated from version $CURRENT_VERSION to $LATEST_VERSION"
print_status "Backup available at: $BACKUP_PATH"

# Log successful update
log "SUCCESS" "Update completed: $CURRENT_VERSION -> $LATEST_VERSION" 