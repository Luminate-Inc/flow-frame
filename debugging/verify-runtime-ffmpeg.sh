#!/bin/bash

echo "=== Verifying FFmpeg Runtime Installation ==="

echo "Contents of /usr/local/lib (first 20 files):"
ls -la /usr/local/lib/ | head -20

echo "Total files in /usr/local/lib: $(ls -1 /usr/local/lib/ | wc -l)"

echo "FFmpeg libraries specifically (libav*):"
ls -la /usr/local/lib/libav* 2>/dev/null || echo "No libav* files found"

echo "Other av-related files:"
find /usr/local/lib -name "*av*" -type f 2>/dev/null || echo "No av-related files found"

echo "FFmpeg binaries:"
ls -la /usr/local/bin/ffmpeg* 2>/dev/null || echo "No ffmpeg binaries found"

echo "=== Setting up library cache ==="
echo "/usr/local/lib" > /etc/ld.so.conf.d/custom-libs.conf
ldconfig

echo "=== Runtime Library Verification ==="
echo "Runtime SDL2 version: $(pkg-config --modversion sdl2 2>/dev/null || echo 'NOT_AVAILABLE')"
echo "Runtime SDL2 TTF version: $(pkg-config --modversion SDL2_ttf 2>/dev/null || echo 'NOT_AVAILABLE')"
echo "Runtime FFmpeg version: $(ffmpeg -version 2>/dev/null | head -1 || echo 'NOT_AVAILABLE')"

echo "Available SDL2 libraries:"
ldconfig -p | grep -i sdl || echo "No SDL2 libraries found"

echo "Available FFmpeg libraries (searching for 'libav'):"
ldconfig -p | grep -i libav || echo "No libav libraries found in ldconfig"

echo "Available FFmpeg libraries (searching for 'ffmpeg'):"
ldconfig -p | grep -i ffmpeg || echo "No ffmpeg libraries found in ldconfig"

echo "All libraries in ldconfig cache:"
ldconfig -p | wc -l && echo "total libraries cached"

echo "=== Runtime verification complete ===" 