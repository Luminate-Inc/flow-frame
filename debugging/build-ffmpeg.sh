#!/bin/bash
set -e

echo "=== Building FFmpeg with hardware decode support ==="

# Clone FFmpeg
echo "=== Cloning FFmpeg ===" 
git clone --depth 1 --branch n${FFMPEG_VERSION} https://github.com/FFmpeg/FFmpeg.git /tmp/ffmpeg
cd /tmp/ffmpeg

# Configure FFmpeg
echo "=== Configuring FFmpeg ==="
./configure \
    --prefix=/usr/local \
    --enable-gpl --enable-version3 \
    --enable-libdrm    \
    --enable-libv4l2   \
    --enable-decoder=hevc_v4l2request \
    --enable-hwaccel=hevc_v4l2request \
    --enable-shared --disable-static \
    --disable-alsa \
    --disable-sndio \
    --disable-xlib \
    --disable-libxcb \
    --disable-sdl2 \
    --enable-bzlib \
    --enable-zlib \
    --enable-lzma \
    --disable-doc \
    --disable-htmlpages \
    --disable-manpages \
    --disable-podpages \
    --disable-txtpages

# Build FFmpeg
echo "=== FFmpeg configure completed, starting build ==="
make -j$(nproc) 2>&1 | tee /tmp/ffmpeg-build.log

# Install FFmpeg
echo "=== FFmpeg build completed, installing ==="
make install 2>&1 | tee /tmp/ffmpeg-install.log

# Post-install verification
echo "=== Post-install verification ==="
echo "/usr/local/lib" > /etc/ld.so.conf.d/ffmpeg.conf
ldconfig
echo "FFmpeg libraries created:"
ls -la /usr/local/lib/libav*
echo "FFmpeg binaries created:"
ls -la /usr/local/bin/ffmpeg*
echo "FFmpeg pkg-config files:"
ls -la /usr/local/lib/pkgconfig/libav* 2>/dev/null || echo "No libav pkg-config files found"
echo "Testing FFmpeg binary:"
/usr/local/bin/ffmpeg -version | head -3
echo "=== ldconfig verification ==="
ldconfig -p | grep -i libav
echo "=== pkg-config verification ==="
pkg-config --exists --print-errors libavformat libavcodec libavutil
echo "pkg-config verification successful"
echo "=== FFmpeg build verification complete ==="

# Cleanup
cd / && rm -rf /tmp/ffmpeg 