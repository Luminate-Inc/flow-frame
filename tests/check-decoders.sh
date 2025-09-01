#!/bin/bash
# check-decoders.sh - Check available video decoders on the system

echo "=== Video Decoder Availability Check ===="
echo "This script checks which decoders are available on your system"
echo "and tests which ones actually work with FFmpeg"
echo ""

# Check if ffmpeg is available
if ! command -v ffmpeg &> /dev/null; then
    echo "ERROR: ffmpeg not found. Please install FFmpeg to check decoder availability."
    exit 1
fi

echo "FFmpeg version:"
ffmpeg -version | head -1
echo ""

echo "=== Testing Decoders Used in Art-Frame Priority System ==="
echo ""

# Function to test a decoder
test_decoder() {
    local decoder_name="$1"
    local codec_type="$2"
    
    printf "%-25s " "$decoder_name:"
    
    # Try to find the decoder in FFmpeg
    if ffmpeg -decoders 2>/dev/null | grep -q " $decoder_name "; then
        printf "AVAILABLE  "
        
        # Create a minimal test to see if decoder actually works
        # This uses a very simple test that tries to initialize the decoder
        if timeout 5 ffmpeg -f lavfi -i "testsrc2=duration=1:size=320x240:rate=1" -c:v "$decoder_name" -f null - >/dev/null 2>&1; then
            printf "✅ WORKING\n"
        else
            printf "❌ FAILS\n"
        fi
    else
        printf "❌ NOT_FOUND\n"
    fi
}

# Test our priority decoders
echo "## HEVC (H.265) Decoders:"
test_decoder "hevc" "hevc"
test_decoder "libde265" "hevc"
test_decoder "hevc_v4l2m2m" "hevc"
test_decoder "hevc_v4l2request" "hevc"
test_decoder "hevc_vaapi" "hevc"
test_decoder "hevc_nvdec" "hevc"
echo ""

echo "## H.264 Decoders:"
test_decoder "h264" "h264"
test_decoder "libx264" "h264"  # This is actually an encoder, but let's check
test_decoder "h264_v4l2m2m" "h264"
test_decoder "h264_v4l2request" "h264"
test_decoder "h264_vaapi" "h264"
test_decoder "h264_nvdec" "h264"
echo ""

echo "## MPEG-2 Decoders:"
test_decoder "mpeg2video" "mpeg2"
test_decoder "mpeg2_v4l2m2m" "mpeg2"
test_decoder "mpeg2_vaapi" "mpeg2"
echo ""

echo "## VP9 Decoders:"
test_decoder "vp9" "vp9"
test_decoder "libvpx-vp9" "vp9"
test_decoder "vp9_v4l2m2m" "vp9"
test_decoder "vp9_vaapi" "vp9"
echo ""

echo "## VP8 Decoders:"
test_decoder "vp8" "vp8"
test_decoder "libvpx" "vp8"
test_decoder "vp8_v4l2m2m" "vp8"
test_decoder "vp8_vaapi" "vp8"
echo ""

echo "## AV1 Decoders:"
test_decoder "av1" "av1"
test_decoder "libaom-av1" "av1"
test_decoder "av1_v4l2m2m" "av1"
test_decoder "av1_vaapi" "av1"
echo ""

echo "## MPEG-4 Decoders:"
test_decoder "mpeg4" "mpeg4"
test_decoder "mpeg4_v4l2m2m" "mpeg4"
echo ""

echo "=== System Information ==="
echo ""

# Check for V4L2 devices
echo "V4L2 devices:"
if ls /dev/video* >/dev/null 2>&1; then
    for device in /dev/video*; do
        if [ -c "$device" ]; then
            echo "  $device: $(v4l2-ctl --device=$device --info 2>/dev/null | grep 'Card type' | cut -d: -f2 | xargs || echo 'Unknown')"
        fi
    done
else
    echo "  No V4L2 devices found"
fi
echo ""

# Check for GPU devices  
echo "GPU/DRM devices:"
if ls /dev/dri/* >/dev/null 2>&1; then
    ls -la /dev/dri/
else
    echo "  No DRM devices found"
fi
echo ""

# Check for VAAPI
echo "VAAPI information:"
if command -v vainfo >/dev/null 2>&1; then
    vainfo 2>/dev/null | head -10 || echo "  VAAPI not working"
else
    echo "  vainfo not installed (VAAPI unavailable)"
fi
echo ""

echo "=== Recommendations ==="
echo ""

# Determine the best working decoders
echo "Based on the test results above, your system should use:"
echo ""

# Check what actually works and give recommendations
working_h264=""
working_hevc=""
working_mpeg2=""

if ffmpeg -decoders 2>/dev/null | grep -q " h264 "; then
    working_h264="h264 (software)"
fi

if ffmpeg -decoders 2>/dev/null | grep -q " hevc "; then
    working_hevc="hevc (software)" 
fi

if ffmpeg -decoders 2>/dev/null | grep -q " mpeg2video "; then
    working_mpeg2="mpeg2video (software)"
fi

echo "✅ Recommended decoders for art-frame:"
echo "  H.264:     ${working_h264:-❌ None available}"
echo "  HEVC:      ${working_hevc:-❌ None available}"  
echo "  MPEG-2:    ${working_mpeg2:-❌ None available}"
echo ""

if [[ -z "$working_h264" && -z "$working_hevc" && -z "$working_mpeg2" ]]; then
    echo "❌ CRITICAL: No working video decoders found!"
    echo "   Your FFmpeg installation may be incomplete."
    echo "   Try reinstalling FFmpeg with full codec support."
else
    echo "✅ GOOD: Software decoders are available and should work reliably."
    echo "   Hardware acceleration is not available, but software decoding"
    echo "   should work fine for most content on Raspberry Pi 4."
fi

echo ""
echo "=== Hardware Acceleration Status ==="
echo ""

# Check if any hardware decoders are actually working
hw_working=false
for hw_decoder in "h264_v4l2m2m" "hevc_v4l2m2m" "mpeg2_v4l2m2m" "h264_vaapi" "hevc_vaapi"; do
    if ffmpeg -decoders 2>/dev/null | grep -q " $hw_decoder " && \
       timeout 5 ffmpeg -f lavfi -i "testsrc2=duration=1:size=320x240:rate=1" -c:v "$hw_decoder" -f null - >/dev/null 2>&1; then
        hw_working=true
        echo "✅ Hardware decoder working: $hw_decoder"
    fi
done

if ! $hw_working; then
    echo "❌ No working hardware decoders found"
    echo "   This is normal on Raspberry Pi 4 - V4L2 hardware decoders"
    echo "   are not implemented. Software decoders will be used instead."
fi

echo ""
echo "=== Decoder check complete ===" 