#!/bin/bash
# test-gpu-access.sh - Test GPU access and display configuration

set -e

echo "=== Art Frame GPU Access Test ==="
echo "This script tests if the GPU access fixes are working"
echo ""

echo "1. Rebuilding container with GPU fixes (balenaOS compatible)..."
docker-compose build --no-cache

echo ""
echo "2. Stopping existing containers..."
docker-compose down

echo ""
echo "3. Starting container with new configuration..."
docker-compose up -d

echo ""
echo "4. Waiting for container to start..."
sleep 10

echo ""
echo "5. Checking container status..."
docker-compose ps

echo ""
echo "6. Testing GPU device access..."
echo "Checking if GPU devices are accessible in container:"

if docker-compose exec art-frame test -c /dev/dri/card0; then
    echo "✅ /dev/dri/card0 accessible"
else
    echo "❌ /dev/dri/card0 not accessible"
fi

if docker-compose exec art-frame test -c /dev/vchiq; then
    echo "✅ /dev/vchiq accessible"
else
    echo "❌ /dev/vchiq not accessible"
fi

if docker-compose exec art-frame test -c /dev/vcsm-cma; then
    echo "✅ /dev/vcsm-cma accessible"
else
    echo "❌ /dev/vcsm-cma not accessible"
fi

echo ""
echo "7. Checking user groups..."
echo "Container user groups:"
docker-compose exec art-frame groups

echo ""
echo "8. Testing GPU access permissions..."
if docker-compose exec art-frame sh -c 'cat /dev/dri/card0 > /dev/null 2>&1'; then
    echo "✅ GPU access permissions working"
else
    echo "❌ GPU access permissions failed"
fi

echo ""
echo "9. Checking for V3D errors in logs..."
sleep 5
if docker-compose logs 2>&1 | grep -q "Couldn't get V3D core IDENT0"; then
    echo "❌ V3D errors still present"
    echo "Recent V3D errors:"
    docker-compose logs 2>&1 | grep "V3D core IDENT0" | tail -3
else
    echo "✅ No V3D errors found"
fi

echo ""
echo "10. Display initialization check..."
if docker-compose logs 2>&1 | grep -q "SDL2 Video Driver: KMSDRM"; then
    echo "✅ KMSDRM driver initialized"
else
    echo "❌ KMSDRM driver not found"
fi

if docker-compose logs 2>&1 | grep -q "Using software renderer"; then
    echo "⚠️  Still using software renderer"
else
    echo "✅ Hardware renderer active"
fi

echo ""
echo "11. Final status check..."
if docker-compose ps art-frame | grep -q "Up"; then
    echo "✅ Container running"
    echo ""
    echo "=== Test Complete ==="
    echo ""
    echo "To monitor logs continuously:"
    echo "  docker-compose logs -f"
    echo ""
    echo "To check your display:"
    echo "  Look at your Pi's connected monitor/TV"
    echo "  You should see the art frame application"
else
    echo "❌ Container not running"
    echo ""
    echo "Check logs for errors:"
    echo "  docker-compose logs"
fi

echo ""
echo "=== Recent Application Logs ==="
docker-compose logs --tail=20 