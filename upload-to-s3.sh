#!/bin/bash

# Art Frame S3 Upload Script
# This script packages the codebase and uploads it to AWS S3
#
# Usage:
#   ./upload-to-s3.sh [version-tag]
#
# Environment Variables:
#   ART_FRAME_S3_BUCKET   - S3 bucket name containing the codebase
#   AWS_ACCESS_KEY_ID     - AWS access key
#   AWS_SECRET_ACCESS_KEY - AWS secret key
#   AWS_DEFAULT_REGION    - AWS region (default: us-east-1)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is not installed. Please install it first:"
    echo "  Ubuntu/Debian: sudo apt-get install awscli"
    echo "  CentOS/RHEL: sudo yum install awscli"
    echo "  Or: pip install awscli"
    exit 1
fi

# Validate arguments
if [ $# -lt 1 ]; then
    print_error "Usage: $0 [version-tag]"
    exit 1
fi

VERSION_TAG="${1:-$(date +%Y%m%d_%H%M%S)}"
BUCKET_NAME="${ART_FRAME_S3_BUCKET:-software-releases}"
PROJECT_DIR="$(pwd)"
TEMP_DIR="/tmp/art-frame-upload"
ARCHIVE_NAME="art-frame-${VERSION_TAG}.tar.gz"

print_status "Starting art-frame codebase upload to S3"
print_status "Bucket: $BUCKET_NAME"
print_status "Version: $VERSION_TAG"
print_status "Project Directory: $PROJECT_DIR"

# Verify AWS credentials
print_status "Checking AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS credentials not configured. Please run:"
    echo "  aws configure"
    echo "Or set environment variables:"
    echo "  export AWS_ACCESS_KEY_ID=your_access_key"
    echo "  export AWS_SECRET_ACCESS_KEY=your_secret_key"
    echo "  export AWS_DEFAULT_REGION=us-east-1"
    exit 1
fi

# Check if bucket exists, create if not
print_status "Checking if S3 bucket exists..."
if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    print_warning "Bucket $BUCKET_NAME does not exist. Creating..."
    aws s3 mb "s3://$BUCKET_NAME"
    print_success "Created bucket: $BUCKET_NAME"
fi

# Create temporary directory
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# Copy project files (excluding binaries and temporary files)
print_status "Packaging codebase..."
cd "$PROJECT_DIR"

# Create exclusion list
cat > "$TEMP_DIR/exclude.txt" << EOF
art-frame
.git/*
.DS_Store
*.log
*.tmp
tmp/*
build/*
dist/*
node_modules/*
.env
EOF

# Create archive with exclusions
tar --exclude-from="$TEMP_DIR/exclude.txt" \
    -czf "$TEMP_DIR/$ARCHIVE_NAME" \
    -C "$PROJECT_DIR" .

# Calculate checksums
ARCHIVE_PATH="$TEMP_DIR/$ARCHIVE_NAME"

# Cross-platform compatibility for checksum and file size commands
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    MD5_HASH=$(md5 -q "$ARCHIVE_PATH")
    SHA256_HASH=$(shasum -a 256 "$ARCHIVE_PATH" | cut -d' ' -f1)
    FILE_SIZE=$(stat -f%z "$ARCHIVE_PATH")
else
    # Linux
    MD5_HASH=$(md5sum "$ARCHIVE_PATH" | cut -d' ' -f1)
    SHA256_HASH=$(sha256sum "$ARCHIVE_PATH" | cut -d' ' -f1)
    FILE_SIZE=$(stat -c%s "$ARCHIVE_PATH")
fi

print_success "Archive created: $ARCHIVE_NAME"

# Format file size in human-readable format
if command -v numfmt &> /dev/null; then
    FORMATTED_SIZE=$(numfmt --to=iec-i --suffix=B $FILE_SIZE)
else
    # Fallback for systems without numfmt (like macOS)
    if [ $FILE_SIZE -gt 1073741824 ]; then
        FORMATTED_SIZE=$(echo "scale=1; $FILE_SIZE/1073741824" | bc)GB
    elif [ $FILE_SIZE -gt 1048576 ]; then
        FORMATTED_SIZE=$(echo "scale=1; $FILE_SIZE/1048576" | bc)MB
    elif [ $FILE_SIZE -gt 1024 ]; then
        FORMATTED_SIZE=$(echo "scale=1; $FILE_SIZE/1024" | bc)KB
    else
        FORMATTED_SIZE="${FILE_SIZE}B"
    fi
fi

print_status "File size: $FORMATTED_SIZE"
print_status "MD5: $MD5_HASH"
print_status "SHA256: $SHA256_HASH"

# Create metadata file
METADATA_FILE="$TEMP_DIR/metadata.json"
cat > "$METADATA_FILE" << EOF
{
  "version": "$VERSION_TAG",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)",
  "archive_name": "$ARCHIVE_NAME",
  "md5_hash": "$MD5_HASH",
  "sha256_hash": "$SHA256_HASH",
  "file_size": $FILE_SIZE,
  "upload_user": "$(whoami)",
  "git_commit": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "git_branch": "$(git branch --show-current 2>/dev/null || echo 'unknown')"
}
EOF

print_status "Created metadata file"

# Upload files to S3
print_status "Uploading archive to S3..."
aws s3 cp "$ARCHIVE_PATH" "s3://$BUCKET_NAME/releases/$ARCHIVE_NAME" \
    --metadata "version=$VERSION_TAG,md5=$MD5_HASH,sha256=$SHA256_HASH"

print_status "Uploading metadata..."
aws s3 cp "$METADATA_FILE" "s3://$BUCKET_NAME/releases/metadata-${VERSION_TAG}.json"

# Update latest metadata
print_status "Updating latest version pointer..."
aws s3 cp "$METADATA_FILE" "s3://$BUCKET_NAME/latest.json"

# Update version list
print_status "Updating version list..."
VERSION_LIST_FILE="$TEMP_DIR/versions.json"
if aws s3 cp "s3://$BUCKET_NAME/versions.json" "$VERSION_LIST_FILE" 2>/dev/null; then
    # Append to existing list
    python3 -c "
import json
import sys

try:
    with open('$VERSION_LIST_FILE', 'r') as f:
        versions = json.load(f)
except:
    versions = {'versions': []}

if 'versions' not in versions:
    versions = {'versions': []}

with open('$METADATA_FILE', 'r') as f:
    new_version = json.load(f)

versions['versions'].append(new_version)
versions['versions'] = sorted(versions['versions'], key=lambda x: x['timestamp'], reverse=True)

with open('$VERSION_LIST_FILE', 'w') as f:
    json.dump(versions, f, indent=2)
"
else
    # Create new list
    echo '{"versions": []}' > "$VERSION_LIST_FILE"
    python3 -c "
import json

with open('$METADATA_FILE', 'r') as f:
    new_version = json.load(f)

versions = {'versions': [new_version]}

with open('$VERSION_LIST_FILE', 'w') as f:
    json.dump(versions, f, indent=2)
"
fi

aws s3 cp "$VERSION_LIST_FILE" "s3://$BUCKET_NAME/versions.json"

# Clean up
rm -rf "$TEMP_DIR"

print_success "Upload completed successfully!"
print_status "Archive uploaded to: s3://$BUCKET_NAME/releases/$ARCHIVE_NAME"
print_status "Latest metadata: s3://$BUCKET_NAME/latest.json"
print_status "Version list: s3://$BUCKET_NAME/versions.json"

echo
print_status "To configure auto-update on your devices:"
echo "  1. Set environment variables:"
echo "     export ART_FRAME_S3_BUCKET='$BUCKET_NAME'"
echo "     export AWS_ACCESS_KEY_ID='your_access_key'"
echo "     export AWS_SECRET_ACCESS_KEY='your_secret_key'"
echo "     export AWS_DEFAULT_REGION='$(aws configure get region || echo us-east-1)'"
echo "  2. Run the update script: ./update.sh" 