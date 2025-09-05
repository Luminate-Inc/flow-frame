#!/bin/bash
# test-display.sh - Quick rebuild and test for display issues

set -e

echo "=== Art Frame Display Test Script ==="
echo "This script will rebuild the container with the new display configuration"
echo "and test the improved decoder fallback system"

# Build the container
echo "Building container..."
docker-compose build --no-cache

echo "Stopping any existing containers..."
docker-compose down

echo "Starting container with new display configuration..."
docker-compose up -d

echo "Waiting for container to start..."
sleep 10

echo "Checking container status..."
docker-compose ps

echo "Following logs for 30 seconds to check display initialization..."
timeout 30 docker-compose logs -f || true

echo ""
echo "=== Quick Status Check ==="
echo "Container status:"
docker-compose ps flow-frame

echo ""
echo "=== Decoder Availability Test ==="
echo "Checking which decoders are available in the container..."
if docker-compose ps flow-frame | grep -q "Up"; then
    echo "Running decoder check inside container..."
    docker-compose exec flow-frame tests/check-decoders.sh 2>/dev/null | head -20 || echo "Could not run decoder check"
else
    echo "Container not running - cannot check decoders"
fi

echo ""
echo "=== Test Commands ==="
echo "To follow logs continuously, run:"
echo "  docker-compose logs -f"

echo ""
echo "To check decoder availability, run:"
echo "  docker-compose exec flow-frame tests/check-decoders.sh"

echo ""
echo "To test different decoders, run:"
echo "  ./test-decoders.sh"

echo ""
echo "To check if the app is displaying on your Pi screen:"
echo "1. Look at your Pi's display - you should see the art frame"
echo "2. Check the logs above for 'SDL2 Video Driver: KMSDRM'"
echo "3. Look for 'Display Configuration Debug' information"

echo ""
echo "If still not working, check:"
echo "1. GPU device permissions: ls -la /dev/dri/"
echo "2. User groups on Pi: groups"
echo "3. GPU memory configuration in Pi config" 