#!/bin/bash

echo "=== Library Mismatch Detection ==="

if [ -f "/usr/local/bin/build-info.txt" ]; then
    source /usr/local/bin/build-info.txt
    echo "Build-time versions:"
    echo "  SDL2: ${SDL2_VERSION:-UNKNOWN}"
    echo "  SDL2_TTF: ${SDL2_TTF_VERSION:-UNKNOWN}"
    echo "  FFmpeg: ${FFMPEG_VERSION:-UNKNOWN}"
    echo ""
    
    echo "Runtime versions:"
    RUNTIME_SDL2=$(pkg-config --modversion sdl2 2>/dev/null || echo "NOT_FOUND")
    RUNTIME_SDL2_TTF=$(pkg-config --modversion SDL2_ttf 2>/dev/null || echo "NOT_FOUND")
    RUNTIME_FFMPEG=$(ffmpeg -version 2>/dev/null | head -1 || echo "NOT_FOUND")
    echo "  SDL2: $RUNTIME_SDL2"
    echo "  SDL2_TTF: $RUNTIME_SDL2_TTF"
    echo "  FFmpeg: $RUNTIME_FFMPEG"
    echo ""
    
    # Check for mismatches (non-fatal)
    if [ "$SDL2_VERSION" != "$RUNTIME_SDL2" ] && [ "$RUNTIME_SDL2" != "NOT_FOUND" ]; then
        echo "WARNING: SDL2 version mismatch!"
        echo "  Built with: $SDL2_VERSION"
        echo "  Runtime has: $RUNTIME_SDL2"
    fi
    if [ "$SDL2_TTF_VERSION" != "$RUNTIME_SDL2_TTF" ] && [ "$RUNTIME_SDL2_TTF" != "NOT_FOUND" ]; then
        echo "WARNING: SDL2_TTF version mismatch!"
        echo "  Built with: $SDL2_TTF_VERSION"
        echo "  Runtime has: $RUNTIME_SDL2_TTF"
    fi
else
    echo "Build info not found - skipping version check"
fi

echo ""
echo "=== Binary Dependencies ==="
if ldd /usr/local/bin/flow-frame 2>/dev/null; then
    echo ""
    echo "Checking for missing dependencies..."
    if ldd /usr/local/bin/flow-frame 2>/dev/null | grep -q "not found"; then
        echo "ERROR: Missing dependencies found:"
        ldd /usr/local/bin/flow-frame 2>/dev/null | grep "not found"
        exit 1
    else
        echo "All dependencies resolved successfully"
    fi
else
    echo "Could not check dependencies"
fi

echo "=== Library verification complete ===" 