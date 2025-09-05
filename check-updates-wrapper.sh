#!/bin/bash

# Art Frame systemd service wrapper for ExecStartPre
# This script sets up the environment and checks for updates before the main application starts
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | logger -t flow-frame
}

log "Art Frame service wrapper (ExecStartPre) - setting up environment"

# Set up environment variables
export HOME="$SCRIPT_DIR"
export DISPLAY="${DISPLAY:-:0}"
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-kmsdrm}"

# Load environment file if it exists
if [ -f "$SCRIPT_DIR/.env" ]; then
    log "Loading environment from .env file"
    set -a  # automatically export all variables
    source "$SCRIPT_DIR/.env"
    set +a  # stop automatically exporting
fi

# Check for updates if configured (but don't apply them here)
check_for_updates() {
    local s3_bucket="$ART_FRAME_S3_BUCKET"
    local update_script="$SCRIPT_DIR/update.sh"
    
    if [ -z "$s3_bucket" ] || [ "$s3_bucket" = "your-bucket-name" ]; then
        log "Auto-update not configured (no S3 bucket set)"
        return 0
    fi
    
    if [ ! -f "$update_script" ] || [ ! -x "$update_script" ]; then
        log "Update script not found or not executable, skipping auto-update check"
        return 0
    fi
    
    if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
        log "AWS credentials not available, skipping auto-update check"
        return 0
    fi
    
    log "Checking for updates in background..."
    
    # Run update check in background (non-blocking) using nohup to detach from service
    (
        # Set up environment variables in the background process
        cd "$SCRIPT_DIR"
        
        # Load environment file if it exists
        if [ -f "$SCRIPT_DIR/.env" ]; then
            set -a  # automatically export all variables
            source "$SCRIPT_DIR/.env"
            set +a  # stop automatically exporting
        fi
        
        # Wait a bit for the application to fully start
        sleep 15
        
        # Run update check with --check-only first
        if "$update_script" --check-only; then
            log "No update needed"
        else
            exit_code=$?
            if [ $exit_code -eq 2 ]; then
                # Update available (exit code 2)
                log "Update available, scheduling update for next restart"
                
                # Instead of applying update immediately, create a flag file
                # that will trigger the update on the next service restart
                echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$SCRIPT_DIR/.update_pending"
                log "Update pending flag created - will apply on next restart"
            else
                log "Update check failed with exit code $exit_code"
            fi
        fi
    ) > /dev/null 2>&1 &
    
    # Don't wait for the update process
    return 0
}

# Check if there's a pending update that needs to be applied
apply_pending_update() {
    local pending_file="$SCRIPT_DIR/.update_pending"
    local update_script="$SCRIPT_DIR/update.sh"
    
    if [ -f "$pending_file" ]; then
        log "Pending update detected, applying now..."
        
        # Remove the pending flag first
        rm -f "$pending_file"
        
        # Ensure environment variables are loaded for the update script
        if [ -f "$SCRIPT_DIR/.env" ]; then
            set -a  # automatically export all variables
            source "$SCRIPT_DIR/.env"
            set +a  # stop automatically exporting
        fi
        
        # Apply the update
        if "$update_script"; then
            log "Update completed successfully"
            # The start script will use the new binary thats built
            exit 0
        else
            log "Update failed, continuing with current version"
        fi
    fi
}

# Verify the main executable exists
if [ ! -f "$SCRIPT_DIR/flow-frame" ]; then
    log "ERROR: Main executable not found: $SCRIPT_DIR/flow-frame"
    exit 1
fi

if [ ! -x "$SCRIPT_DIR/flow-frame" ]; then
    log "ERROR: Main executable not executable: $SCRIPT_DIR/flow-frame"
    exit 1
fi

log "Environment setup complete, main executable verified"

# Apply any pending updates first
apply_pending_update

log "ExecStartPre completed successfully"

# Start update check in background (non-blocking)
check_for_updates

# Exit successfully - the main ExecStart command will handle running the application
exit 0 