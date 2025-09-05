#!/bin/bash
# test-decoders.sh - Test different video decoder configurations

set -e

echo "=== Video Decoder Priority Test Script ==="
echo "This script helps test the new priority-based decoder selection"
echo "Use this script to debug decoder initialization issues"

# Function to test decoder with specific settings
test_decoder_config() {
    local config_name="$1"
    local env_vars="$2"
    
    echo ""
    echo "=== Testing Configuration: $config_name ==="
    echo "Environment: $env_vars"
    
    # Stop any running containers
    docker-compose down --timeout 5 > /dev/null 2>&1 || true
    
    # Start with specific environment
    if [ -n "$env_vars" ]; then
        eval "docker-compose run --rm -e $env_vars flow-frame" &
    else
        docker-compose run --rm flow-frame &
    fi
    
    local pid=$!
    
    # Let it run for 15 seconds to see decoder selection
    echo "Running for 15 seconds to check decoder selection..."
    sleep 15
    
    # Kill the test run
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    
    echo "Configuration test complete"
}

echo ""
echo "Available test configurations:"
echo "1. Default priority system (HEVC > H.264 > others)"
echo "2. Force software decoding"
echo "3. Debug all available decoders"
echo "4. Force specific hardware decoder"
echo "5. Enable detailed decoder debugging"

read -p "Select configuration (1-5): " choice

case $choice in
    1)
        echo "Testing default priority system..."
        test_decoder_config "Default Priority" ""
        ;;
    2)
        echo "Testing forced software decoding..."
        test_decoder_config "Software Only" "FORCE_SOFTWARE_DECODER=1"
        ;;
    3)
        echo "Testing with decoder debugging..."
        test_decoder_config "Debug Decoders" "DEBUG_DECODERS=1"
        ;;
    4)
        echo "Available hardware decoders for manual testing:"
        echo "  - h264_v4l2request (Pi 5 H.264 V4L2 Request API)"
        echo "  - hevc_v4l2request (Pi 5 HEVC V4L2 Request API)"
        echo "  - h264_v4l2m2m (Pi H.264 mem2mem)"
        echo "  - hevc_v4l2m2m (Pi HEVC mem2mem)"
        read -p "Enter specific decoder name: " decoder_name
        test_decoder_config "Manual Decoder" "VIDEO_DECODER=$decoder_name"
        ;;
    5)
        echo "Testing with detailed debugging..."
        test_decoder_config "Full Debug" "DEBUG_DECODERS=1 SDL_VIDEODRIVER=kmsdrm"
        ;;
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac

echo ""
echo "=== Decoder Test Complete ==="
echo ""
echo "To check the results:"
echo "1. Look for 'Stream codec ID:' to see what codec your videos use"
echo "2. Look for 'Detected [codec] stream, prioritizing [codec] decoders'"
echo "3. Look for 'Selected priority decoder:' to see which decoder was chosen"
echo "4. Look for 'Successfully opened decoder:' for final confirmation"
echo ""
echo "Common codec IDs:"
echo "  - 27 = H.264 (AV_CODEC_ID_H264)"
echo "  - 173 = HEVC/H.265 (AV_CODEC_ID_HEVC)"
echo "  - 2 = MPEG-2 (AV_CODEC_ID_MPEG2VIDEO)"
echo "  - 12 = MPEG-4 (AV_CODEC_ID_MPEG4)"
echo ""
echo "For continuous monitoring:"
echo "  docker-compose logs -f | grep -E '(decoder|codec|Stream)'" 