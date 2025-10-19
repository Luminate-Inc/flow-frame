#!/bin/bash
#
# Flow Frame Update Manager Script
# Checks for version updates from luminateflow.ca/releases and updates the binary if needed
#
# This script is designed to run as a systemd service on Debian-based systems
# It requires the APP_VERSION environment variable to be set by the systemd service
#
# Exit codes:
#   0 - Success (updated or no update needed)
#   1 - Fatal error (network failure, invalid response, etc.)

set -euo pipefail

# Configuration
RELEASE_ENDPOINT="https://luminateflow.ca/api/releases"
BINARY_PATH="/usr/local/bin/flow-frame"
BACKUP_PATH="/usr/local/bin/flow-frame.backup"
TEMP_BINARY="/tmp/flow-frame-download-$$"
ENV_FILE="/opt/flowframe/.env"
LOG_TAG="flow-frame-updater"

# Logging functions
log_info() {
    echo "[INFO] $*" | logger -t "$LOG_TAG" -s 2>&1
}

log_error() {
    echo "[ERROR] $*" | logger -t "$LOG_TAG" -s -p user.err 2>&1
}

log_warn() {
    echo "[WARN] $*" | logger -t "$LOG_TAG" -s -p user.warning 2>&1
}

# Cleanup function
cleanup() {
    if [ -f "$TEMP_BINARY" ]; then
        rm -f "$TEMP_BINARY"
        log_info "Cleaned up temporary files"
    fi
}
trap cleanup EXIT

# Check if APP_VERSION is set
if [ -z "${APP_VERSION:-}" ]; then
    log_error "APP_VERSION environment variable is not set"
    exit 1
fi

log_info "Current version: $APP_VERSION"

# Check for required commands
if ! command -v curl >/dev/null 2>&1; then
    log_error "curl is not installed. Please install it: apt-get install curl"
    exit 1
fi

# Check for jq (JSON parser) - if not available, use python3 fallback
HAS_JQ=false
if command -v jq >/dev/null 2>&1; then
    HAS_JQ=true
    log_info "Using jq for JSON parsing"
elif command -v python3 >/dev/null 2>&1; then
    log_info "Using python3 for JSON parsing (jq not available)"
else
    log_error "Neither jq nor python3 is available for JSON parsing"
    exit 1
fi

# Function to parse JSON
parse_json() {
    local json="$1"
    local field="$2"

    if [ "$HAS_JQ" = true ]; then
        echo "$json" | jq -r ".$field"
    else
        # Python fallback
        echo "$json" | python3 -c "import sys, json; print(json.load(sys.stdin)['$field'])"
    fi
}

# Fetch release information
log_info "Checking for updates from $RELEASE_ENDPOINT"

RESPONSE=""
HTTP_CODE=""

# Make HTTP request with timeout
if ! RESPONSE=$(curl -sSL --max-time 30 --fail --write-out "\n%{http_code}" "$RELEASE_ENDPOINT" 2>/dev/null); then
    log_error "Failed to fetch release information from $RELEASE_ENDPOINT"
    log_error "Network may be unavailable or endpoint is down"
    exit 1
fi

# Extract HTTP status code (last line) and response body
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
    log_error "HTTP request failed with status code: $HTTP_CODE"
    exit 1
fi

log_info "Successfully fetched release information"

# Parse JSON response
REMOTE_VERSION=""
BINARY_URL=""

if ! REMOTE_VERSION=$(parse_json "$RESPONSE_BODY" "version" 2>/dev/null); then
    log_error "Failed to parse 'version' from JSON response"
    log_error "Response: $RESPONSE_BODY"
    exit 1
fi

if ! BINARY_URL=$(parse_json "$RESPONSE_BODY" "go-binary" 2>/dev/null); then
    log_error "Failed to parse 'go-binary' from JSON response"
    log_error "Response: $RESPONSE_BODY"
    exit 1
fi

# Validate parsed values
if [ -z "$REMOTE_VERSION" ] || [ "$REMOTE_VERSION" = "null" ]; then
    log_error "Invalid remote version: '$REMOTE_VERSION'"
    exit 1
fi

if [ -z "$BINARY_URL" ] || [ "$BINARY_URL" = "null" ]; then
    log_error "Invalid binary URL: '$BINARY_URL'"
    exit 1
fi

log_info "Remote version: $REMOTE_VERSION"
log_info "Binary URL: $BINARY_URL"

# Compare versions
if [ "$APP_VERSION" = "$REMOTE_VERSION" ]; then
    log_info "Already running latest version ($APP_VERSION). No update needed."
    exit 0
fi

log_info "Update available: $APP_VERSION -> $REMOTE_VERSION"

# Download new binary
log_info "Downloading new binary from $BINARY_URL"

if ! curl -sSL --max-time 300 --fail -o "$TEMP_BINARY" "$BINARY_URL" 2>/dev/null; then
    log_error "Failed to download binary from $BINARY_URL"
    exit 1
fi

# Verify downloaded file is a valid binary
if ! file "$TEMP_BINARY" | grep -qE "(executable|ELF)"; then
    log_error "Downloaded file is not a valid executable"
    log_error "File type: $(file "$TEMP_BINARY")"
    exit 1
fi

log_info "Binary downloaded successfully"

# Make the downloaded binary executable
chmod +x "$TEMP_BINARY"

# Create backup of current binary
if [ -f "$BINARY_PATH" ]; then
    log_info "Creating backup of current binary at $BACKUP_PATH"
    cp "$BINARY_PATH" "$BACKUP_PATH"
else
    log_warn "Current binary not found at $BINARY_PATH (fresh install?)"
fi

# Atomically replace the binary
log_info "Installing new binary to $BINARY_PATH"
mv -f "$TEMP_BINARY" "$BINARY_PATH"

log_info "Binary replacement successful"

# Update APP_VERSION in the shared environment file
if [ -f "$ENV_FILE" ]; then
    log_info "Updating APP_VERSION in $ENV_FILE to $REMOTE_VERSION"

    # Create backup of env file
    cp "$ENV_FILE" "${ENV_FILE}.backup"

    # Update the APP_VERSION line using sed
    if sed -i "s/^APP_VERSION=.*/APP_VERSION=$REMOTE_VERSION/" "$ENV_FILE"; then
        log_info "Environment file updated successfully"
        # Clean up backup
        rm -f "${ENV_FILE}.backup"
    else
        log_error "Failed to update environment file"
        # Restore backup
        mv "${ENV_FILE}.backup" "$ENV_FILE"
        exit 1
    fi
else
    log_warn "Environment file not found at $ENV_FILE - creating it"
    # Create the directory if it doesn't exist
    mkdir -p "$(dirname "$ENV_FILE")"
    echo "APP_VERSION=$REMOTE_VERSION" > "$ENV_FILE"
    log_info "Created new environment file at $ENV_FILE"
fi

log_info "Update completed successfully: $APP_VERSION -> $REMOTE_VERSION"
log_info "New binary installed at $BINARY_PATH"

exit 0
