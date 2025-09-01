package mpeg

/*
#cgo pkg-config: libavformat libavcodec libavutil libswscale

#include <stdlib.h>
#include <stdio.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <libavutil/log.h>

// ---------------------- C structures ----------------------------

typedef struct {
    AVFormatContext *formatCtx;
    AVCodecContext  *codecCtx;
    AVFrame         *frame;
    AVFrame         *frameRGBA;
    struct SwsContext *swsCtx;
    int             videoStream;
    uint8_t         *bufferRGBA;
} Decoder;

// ----------------------------------------------------------------
// Helper to open an FFmpeg decoder (optionally using hardware accel)
// ----------------------------------------------------------------
int init_decoder(const char *filename, Decoder *d) {
    // Suppress non-critical warnings such as the colourspace-conversion notice.
    av_log_set_level(AV_LOG_ERROR);
    d->videoStream = -1;

    // Track whether we had to fall back to a secondary decoder.
    int didFallback = 0;

    // Open file / stream
    if (avformat_open_input(&d->formatCtx, filename, NULL, NULL) != 0) {
        fprintf(stderr, "Could not open input file '%s'\n", filename);
        return -1;
    }

    if (avformat_find_stream_info(d->formatCtx, NULL) < 0) {
        fprintf(stderr, "Could not find stream information\n");
        return -2;
    }

    // ---------------------------------------------
    // Choose decoder (honouring VIDEO_DECODER env)
    // ---------------------------------------------

    const char *envDecoder = getenv("VIDEO_DECODER");
    const char *forceSwDecoder = getenv("FORCE_SOFTWARE_DECODER");
    const AVCodec *codec = NULL;

    // Debug: Print available decoders
    const char *debugDecoders = getenv("DEBUG_DECODERS");
    if (debugDecoders && strcmp(debugDecoders, "1") == 0) {
        fprintf(stderr, "=== Available decoders ===\n");
        void *iter = NULL;
        const AVCodec *c = NULL;
        while ((c = av_codec_iterate(&iter))) {
            if (av_codec_is_decoder(c)) {
                fprintf(stderr, "  %s (%s)\n", c->name, c->long_name ? c->long_name : "no description");
            }
        }
        fprintf(stderr, "=== End decoder list ===\n");
    }

    // If FORCE_SOFTWARE_DECODER is set, skip hardware decoder selection
    if (forceSwDecoder && strcmp(forceSwDecoder, "1") == 0) {
        fprintf(stderr, "FORCE_SOFTWARE_DECODER=1: Skipping hardware decoder selection\n");
        codec = NULL; // Will fall back to software decoder later
    } else {
        // We'll later verify that the selected codec actually matches the
        // stream's codec_id. If not, we fall back to the default software
        // decoder obtained through avcodec_find_decoder.

        if (envDecoder && envDecoder[0] != '\0') {
            codec = avcodec_find_decoder_by_name(envDecoder);
            if (!codec) {
                fprintf(stderr, "Decoder specified by VIDEO_DECODER ('%s') not found. Falling back to defaults.\n", envDecoder);
            } else {
                fprintf(stderr, "Using decoder from VIDEO_DECODER: %s\n", envDecoder);
            }
        }
    }

    // Platform-specific hardware decoder hint (macOS only)
#ifdef __APPLE__
    if (!codec) {
        codec = avcodec_find_decoder_by_name("hevc_videotoolbox");
    }
#endif

    // Iterate over the streams and find the best decoder per-stream
    for (unsigned int i = 0; i < d->formatCtx->nb_streams; i++) {
        if (d->formatCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            d->videoStream = (int)i;
            enum AVCodecID stream_codec_id = d->formatCtx->streams[i]->codecpar->codec_id;

            fprintf(stderr, "Stream codec ID: %d\n", stream_codec_id);

            // If we already have a matching codec from environment variable, use it
            if (codec && codec->id == stream_codec_id) {
                fprintf(stderr, "Using pre-selected decoder: %s (matches stream codec)\n", codec->name);
                break;
            }

            // Priority-based decoder selection for high-definition codecs
            const char* priority_decoders[32]; // Array to hold decoder priority list
            int decoder_count = 0;

            // Build priority list based on stream codec type
            switch (stream_codec_id) {
                case AV_CODEC_ID_HEVC: // H.265/HEVC
                    fprintf(stderr, "Detected HEVC/H.265 stream, prioritizing HEVC decoders\n");
#ifdef __linux__
                    // NOTE: V4L2 decoders are not working on Raspberry Pi 4
                    // Commenting out until proper kernel drivers are available
                    // priority_decoders[decoder_count++] = "hevc_v4l2request";    // V4L2 request API (not implemented on Pi 4)
                    // priority_decoders[decoder_count++] = "hevc_v4l2m2m";        // HEVC mem2mem (not working on Pi 4)
                    priority_decoders[decoder_count++] = "hevc_rkmpp";          // Rockchip hardware
                    priority_decoders[decoder_count++] = "hevc_vaapi";          // Intel/AMD VAAPI
                    priority_decoders[decoder_count++] = "hevc_nvdec";          // NVIDIA
#endif
#ifdef __APPLE__
                    priority_decoders[decoder_count++] = "hevc_videotoolbox";   // Apple VideoToolbox
#endif
                    priority_decoders[decoder_count++] = "hevc";                // Software (works reliably)
                    break;

                case AV_CODEC_ID_H264: // H.264/AVC
                    fprintf(stderr, "Detected H.264 stream, prioritizing H.264 decoders\n");
#ifdef __linux__
                    // NOTE: V4L2 decoders are not working on Raspberry Pi 4
                    // priority_decoders[decoder_count++] = "h264_v4l2request";    // V4L2 request API (not implemented on Pi 4)
                    // priority_decoders[decoder_count++] = "h264_v4l2m2m";        // H.264 mem2mem (not working on Pi 4)
                    priority_decoders[decoder_count++] = "h264_rkmpp";          // Rockchip hardware
                    priority_decoders[decoder_count++] = "h264_vaapi";          // Intel/AMD VAAPI
                    priority_decoders[decoder_count++] = "h264_nvdec";          // NVIDIA
                    priority_decoders[decoder_count++] = "h264_cuvid";          // NVIDIA CUVID
#endif
#ifdef __APPLE__
                    priority_decoders[decoder_count++] = "h264_videotoolbox";   // Apple VideoToolbox
#endif
                    priority_decoders[decoder_count++] = "h264";                // Software (works reliably)
                    break;

                case AV_CODEC_ID_VP9: // VP9
                    fprintf(stderr, "Detected VP9 stream, prioritizing VP9 decoders\n");
#ifdef __linux__
                    priority_decoders[decoder_count++] = "vp9_v4l2m2m";         // VP9 mem2mem
                    priority_decoders[decoder_count++] = "vp9_vaapi";           // Intel/AMD VAAPI
#endif
                    priority_decoders[decoder_count++] = "vp9";                 // Software fallback
                    break;

                case AV_CODEC_ID_VP8: // VP8
                    fprintf(stderr, "Detected VP8 stream, prioritizing VP8 decoders\n");
#ifdef __linux__
                    priority_decoders[decoder_count++] = "vp8_v4l2m2m";         // VP8 mem2mem
                    priority_decoders[decoder_count++] = "vp8_vaapi";           // Intel/AMD VAAPI
#endif
                    priority_decoders[decoder_count++] = "vp8";                 // Software fallback
                    break;

                case AV_CODEC_ID_AV1: // AV1
                    fprintf(stderr, "Detected AV1 stream, prioritizing AV1 decoders\n");
#ifdef __linux__
                    priority_decoders[decoder_count++] = "av1_v4l2m2m";         // AV1 mem2mem
                    priority_decoders[decoder_count++] = "av1_vaapi";           // Intel/AMD VAAPI
#endif
                    priority_decoders[decoder_count++] = "av1";                 // Software fallback
                    break;

                case AV_CODEC_ID_MPEG2VIDEO: // MPEG-2
                    fprintf(stderr, "Detected MPEG-2 stream, prioritizing MPEG-2 decoders\n");
#ifdef __linux__
                    // NOTE: V4L2 MPEG-2 decoder not working on Raspberry Pi 4
                    // priority_decoders[decoder_count++] = "mpeg2_v4l2m2m";       // MPEG-2 mem2mem (not working on Pi 4)
                    priority_decoders[decoder_count++] = "mpeg2_vaapi";         // Intel/AMD VAAPI
#endif
                    priority_decoders[decoder_count++] = "mpeg2video";          // Software (works reliably)
                    priority_decoders[decoder_count++] = "mpeg2";               // Alternative software
                    break;

                case AV_CODEC_ID_MPEG4: // MPEG-4
                    fprintf(stderr, "Detected MPEG-4 stream, prioritizing MPEG-4 decoders\n");
#ifdef __linux__
                    priority_decoders[decoder_count++] = "mpeg4_v4l2m2m";       // MPEG-4 mem2mem
                    priority_decoders[decoder_count++] = "mpeg4_vaapi";         // Intel/AMD VAAPI
#endif
                    priority_decoders[decoder_count++] = "mpeg4";               // Software fallback
                    break;

                default:
                    fprintf(stderr, "Unknown or legacy codec (id=%d), using default decoder search\n", stream_codec_id);
                    // For unknown codecs, we'll let the default decoder search handle it
                    // V4L2 decoders commented out as they don't work on Raspberry Pi 4
#ifdef __linux__
                    // priority_decoders[decoder_count++] = "h264_v4l2m2m";        // H.264 hardware (not working on Pi 4)
                    // priority_decoders[decoder_count++] = "hevc_v4l2m2m";        // HEVC hardware (not working on Pi 4)
#endif
                    break;
            }

            // Try each decoder in priority order with full initialization test
            codec = NULL;
            d->codecCtx = NULL;
            int decoder_opened = 0;

            for (int j = 0; j < decoder_count; j++) {
                const AVCodec* candidate = avcodec_find_decoder_by_name(priority_decoders[j]);
                if (!candidate) {
                    fprintf(stderr, "Decoder %s not available\n", priority_decoders[j]);
                    continue;
                }

                if (candidate->id != stream_codec_id) {
                    fprintf(stderr, "Skipped decoder %s (id=%d) - doesn't match stream codec %d\n",
                            priority_decoders[j], candidate->id, stream_codec_id);
                    continue;
                }

                fprintf(stderr, "Trying decoder: %s (id=%d) for codec %d\n",
                        candidate->name, candidate->id, stream_codec_id);

                // Test if this decoder can actually be opened
                AVCodecContext* test_ctx = avcodec_alloc_context3(candidate);
                if (!test_ctx) {
                    fprintf(stderr, "Failed to allocate context for decoder: %s\n", candidate->name);
                    continue;
                }

                avcodec_parameters_to_context(test_ctx, d->formatCtx->streams[i]->codecpar);
                test_ctx->thread_type = FF_THREAD_FRAME;
                test_ctx->thread_count = 0;

                if (avcodec_open2(test_ctx, candidate, NULL) < 0) {
                    fprintf(stderr, "Failed to open decoder: %s (hardware not available or misconfigured)\n", candidate->name);
                    avcodec_free_context(&test_ctx);
                    continue;
                }

                // Success! This decoder works
                codec = candidate;
                d->codecCtx = test_ctx;
                decoder_opened = 1;
                fprintf(stderr, "Successfully opened decoder: %s (id=%d) for codec %d\n",
                        codec->name, codec->id, stream_codec_id);
                break;
            }

            // Final fallback to any available decoder for this codec
            if (!decoder_opened) {
                fprintf(stderr, "No priority decoder worked, trying default decoder for codec %d\n", stream_codec_id);
                const AVCodec* default_codec = avcodec_find_decoder(stream_codec_id);
                if (default_codec) {
                    fprintf(stderr, "Trying default decoder: %s\n", default_codec->name);
                    AVCodecContext* test_ctx = avcodec_alloc_context3(default_codec);
                    if (test_ctx) {
                        avcodec_parameters_to_context(test_ctx, d->formatCtx->streams[i]->codecpar);
                        test_ctx->thread_type = FF_THREAD_FRAME;
                        test_ctx->thread_count = 0;

                        if (avcodec_open2(test_ctx, default_codec, NULL) >= 0) {
                            codec = default_codec;
                            d->codecCtx = test_ctx;
                            decoder_opened = 1;
                            didFallback = 1;
                            fprintf(stderr, "Successfully opened default decoder: %s\n", default_codec->name);
                        } else {
                            fprintf(stderr, "Failed to open default decoder: %s\n", default_codec->name);
                            avcodec_free_context(&test_ctx);
                        }
                    }
                }
            }

            if (!decoder_opened || !codec || !d->codecCtx) {
                fprintf(stderr, "Could not find any working decoder for codec id %d\n", stream_codec_id);
                return -3;
            }

            break;
        }
    }
    if (d->videoStream == -1) {
        fprintf(stderr, "No video stream found\n");
        return -3;
    }

    // Codec is already opened in the loop above, no need to open again

    // Debug: Print final decoder info
    fprintf(stderr, "Final decoder ready: %s (id=%d) for stream %dx%d\n",
            codec ? codec->name : "unknown", codec ? codec->id : -1,
            d->codecCtx->width, d->codecCtx->height);

    d->frame = av_frame_alloc();
    d->frameRGBA = av_frame_alloc();

    int width  = d->codecCtx->width;
    int height = d->codecCtx->height;
    int numBytes = av_image_get_buffer_size(AV_PIX_FMT_RGBA, width, height, 1);
    d->bufferRGBA = (uint8_t *)av_malloc(numBytes * sizeof(uint8_t));
    av_image_fill_arrays(d->frameRGBA->data, d->frameRGBA->linesize, d->bufferRGBA, AV_PIX_FMT_RGBA, width, height, 1);

    d->swsCtx = sws_getContext(width, height, d->codecCtx->pix_fmt,
                               width, height, AV_PIX_FMT_RGBA,
                               SWS_BILINEAR, NULL, NULL, NULL);
    return 0;
}

// Decode a single frame. Returns 1 on success, 0 on EOF, negative on error.
int decode_frame(Decoder *d, uint8_t **rgba_data) {
    AVPacket packet;
    int ret;

    while (av_read_frame(d->formatCtx, &packet) >= 0) {
        if (packet.stream_index == d->videoStream) {
            ret = avcodec_send_packet(d->codecCtx, &packet);
            if (ret < 0) {
                av_packet_unref(&packet);
                return -1;
            }
            ret = avcodec_receive_frame(d->codecCtx, d->frame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
                av_packet_unref(&packet);
                continue; // Need more data
            } else if (ret < 0) {
                av_packet_unref(&packet);
                return -2;
            }

            // Convert to RGBA
            sws_scale(d->swsCtx,
                      (const uint8_t * const*)d->frame->data,
                      d->frame->linesize,
                      0,
                      d->codecCtx->height,
                      d->frameRGBA->data,
                      d->frameRGBA->linesize);

            *rgba_data = d->frameRGBA->data[0];
            av_packet_unref(&packet);
            return 1; // Frame decoded
        }
        av_packet_unref(&packet);
    }
    return 0; // EOF
}

void close_decoder(Decoder *d) {
    if (!d) return;
    av_free(d->bufferRGBA);
    av_frame_free(&d->frameRGBA);
    av_frame_free(&d->frame);
    // avcodec_close is deprecated. Use avcodec_free_context instead.
    avcodec_free_context(&d->codecCtx);
    if (d->formatCtx) {
        avformat_close_input(&d->formatCtx);
    }
}

// ----------------------------------------------------------------
// Retrieve the stream's frame-rate (as float). Uses av_guess_frame_rate.
// ----------------------------------------------------------------
double getDecoderFPS(Decoder *d) {
    if (!d || d->videoStream < 0) {
        return 0;
    }
    AVStream *st = d->formatCtx->streams[d->videoStream];
    AVRational r = av_guess_frame_rate(d->formatCtx, st, NULL);
    if (r.den == 0) {
        return 0;
    }
    return av_q2d(r);
}
*/
import "C"

import (
	"fmt"
	"io"
	"log"
	"os"
	"sync"
	"time"
	"unsafe"

	"github.com/veandco/go-sdl2/sdl"
)

// ------------------- Go wrapper around the C decoder -------------------

type videoDecoder struct {
	cdec   C.Decoder
	width  int
	height int
	fps    float64
}

func newVideoDecoder(path string) (*videoDecoder, error) {
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))

	dec := &videoDecoder{}
	if ret := C.init_decoder(cPath, &dec.cdec); ret != 0 {
		if int(ret) == -5 {
			panic(fmt.Sprintf("fatal: fallback decoder failed to open (code=%d)", int(ret)))
		}
		return nil, fmt.Errorf("init_decoder failed (code=%d)", int(ret))
	}

	dec.width = int(dec.cdec.codecCtx.width)
	dec.height = int(dec.cdec.codecCtx.height)

	// Retrieve framerate via a helper C function.
	dec.fps = float64(C.getDecoderFPS(&dec.cdec))
	if dec.fps <= 0 {
		dec.fps = 30 // sensible default if not available
	}
	return dec, nil
}

func (d *videoDecoder) nextFrame() ([]byte, error) {
	var data *C.uint8_t
	ret := C.decode_frame(&d.cdec, &data)
	switch {
	case ret == 0:
		return nil, io.EOF
	case ret < 0:
		return nil, fmt.Errorf("decode error (code=%d)", int(ret))
	}

	bufLen := d.width * d.height * 4 // RGBA
	return C.GoBytes(unsafe.Pointer(data), C.int(bufLen)), nil
}

func (d *videoDecoder) close() {
	C.close_decoder(&d.cdec)
}

// ------------------- Player (SDL2 integration) -------------------

type Player struct {
	dec *videoDecoder

	// SDL2 rendering objects
	renderer *sdl.Renderer
	texture  *sdl.Texture

	// Playback control
	playbackRate float64
	loop         bool
	refTime      time.Time

	// Bounce replay support
	bounce         bool
	bounceFrames   [][]byte // Store raw frame data instead of textures
	playingCached  bool
	cacheIdx       int
	bounceLastTime time.Time
	bounceAcc      float64

	// playback timing
	acc      float64   // accumulated fractional frames
	lastTime time.Time // last wall-clock timestamp

	// book-keeping
	m         sync.Mutex
	closeOnce sync.Once
	src       io.ReadCloser
}

// NewPlayer creates a new FFmpeg-backed video player from an opened *os.File.
// The file must be seekable so that looping works.
func NewPlayer(src io.ReadCloser) (*Player, error) {
	file, ok := src.(*os.File)
	if !ok {
		return nil, fmt.Errorf("NewPlayer: src must be *os.File (got %T)", src)
	}

	dec, err := newVideoDecoder(file.Name())
	if err != nil {
		return nil, err
	}

	p := &Player{
		dec:          dec,
		playbackRate: 1.0,
		loop:         true,
		src:          src,
	}

	// Reset playback counters so that timing resumes smoothly from the start.
	p.acc = 0
	p.lastTime = time.Now()

	return p, nil
}

// SetRenderer sets the SDL2 renderer for this player
func (p *Player) SetRenderer(renderer *sdl.Renderer) error {
	p.m.Lock()
	defer p.m.Unlock()

	p.renderer = renderer

	// Create texture for video frames
	var err error
	p.texture, err = renderer.CreateTexture(uint32(sdl.PIXELFORMAT_RGBA32), sdl.TEXTUREACCESS_STREAMING, int32(p.dec.width), int32(p.dec.height))
	if err != nil {
		return fmt.Errorf("failed to create texture: %v", err)
	}

	// Decode and upload the very first frame right away
	firstFrame, err := p.dec.nextFrame()
	if err != nil {
		return err
	}
	p.updateTexture(firstFrame)

	return nil
}

// updateTexture updates the SDL2 texture with new frame data
func (p *Player) updateTexture(frameData []byte) error {
	if p.texture == nil {
		return fmt.Errorf("texture not initialized")
	}

	pixels, pitch, err := p.texture.Lock(nil)
	if err != nil {
		return fmt.Errorf("failed to lock texture: %v", err)
	}
	defer p.texture.Unlock()

	// Copy frame data to texture
	copy(pixels, frameData)
	_ = pitch // pitch is handled automatically by SDL2

	return nil
}

// PreloadFirstFrame decodes and uploads the very first frame so that Draw has pixels.
func (p *Player) PreloadFirstFrame() error {
	p.m.Lock()
	defer p.m.Unlock()

	if p.texture == nil {
		return fmt.Errorf("renderer not set, call SetRenderer first")
	}

	data, err := p.dec.nextFrame()
	if err != nil {
		return err
	}
	return p.updateTexture(data)
}

// Play marks the reference time so that playback resumes.
func (p *Player) Play() {
	p.m.Lock()
	p.refTime = time.Now()
	p.m.Unlock()
}

// SetPlaybackRate updates the logical playback rate (currently best-effort).
func (p *Player) SetPlaybackRate(rate float64) {
	if rate <= 0 {
		return
	}
	p.m.Lock()
	p.playbackRate = rate
	p.m.Unlock()
}

// SetLoop enables or disables simple looping.
func (p *Player) SetLoop(loop bool) {
	p.m.Lock()
	p.loop = loop
	p.m.Unlock()
}

// SetBounceLoop enables or disables bounce looping.
func (p *Player) SetBounceLoop(bounce bool) {
	p.m.Lock()
	p.bounce = bounce
	if bounce {
		p.loop = false
	}
	p.m.Unlock()
}

// HasEnded reports whether decoding has reached EOF and no bounce/loop is pending.
func (p *Player) HasEnded() bool {
	p.m.Lock()
	defer p.m.Unlock()
	if p.bounce && (p.playingCached || len(p.bounceFrames) > 0) {
		return false
	}
	// If decoder reached EOF previously, dec.nextFrame will keep returning io.EOF.
	// We rely on outer code to treat that as ended.
	return false
}

// Update decodes the next frame (or advances bounce playback).
func (p *Player) Update() error {
	return p.UpdateFrame()
}

func (p *Player) UpdateFrame() error {
	p.m.Lock()
	defer p.m.Unlock()

	// ------------------------------------------------------------
	// Time progression accounting
	// ------------------------------------------------------------
	now := time.Now()
	if p.lastTime.IsZero() {
		p.lastTime = now
	}
	dt := now.Sub(p.lastTime).Seconds()
	p.lastTime = now

	p.acc += dt * p.playbackRate * p.dec.fps

	// Debug frame updates if environment variable is set
	debugFrames := os.Getenv("DEBUG_FRAME_UPDATES")
	if debugFrames == "1" && int(p.acc) > 0 {
		log.Printf("UpdateFrame: dt=%.3fs, acc=%.3f, fps=%.1f, rate=%.2fx, steps=%d",
			dt, p.acc, p.dec.fps, p.playbackRate, int(p.acc))
	}

	// -------------- bounce reverse path ------------------
	if p.bounce && p.playingCached {
		steps := int(p.acc)
		if steps > 0 {
			p.cacheIdx -= steps
			p.acc -= float64(steps)
		}

		if p.cacheIdx < 0 {
			// Finished reverse. Reset state, restart decoder.
			p.playingCached = false
			p.bounceFrames = nil
			p.cacheIdx = 0
			p.acc = 0
			return p.restartLocked()
		}

		if p.cacheIdx >= 0 && p.cacheIdx < len(p.bounceFrames) {
			return p.updateTexture(p.bounceFrames[p.cacheIdx])
		}
		return nil
	}

	// -------------- normal forward path ------------------
	steps := int(p.acc)
	if steps == 0 {
		return nil // not time for next frame yet
	}

	var data []byte
	var err error
	for i := 0; i < steps; i++ {
		data, err = p.dec.nextFrame()
		if err != nil {
			break
		}
	}
	p.acc -= float64(steps)

	if err == io.EOF {
		if p.bounce {
			if len(p.bounceFrames) == 0 {
				// Nothing cached; simple loop fallback.
				return p.restartLocked()
			}
			p.playingCached = true
			p.cacheIdx = len(p.bounceFrames) - 1
			return nil
		}

		if p.loop {
			return p.restartLocked()
		}
		return err
	}
	if err != nil {
		return err
	}

	// Upload to texture
	if err := p.updateTexture(data); err != nil {
		return err
	}

	// Debug successful frame upload
	if debugFrames == "1" {
		log.Printf("UpdateFrame: Successfully decoded and uploaded frame to texture")
	}

	// Save for bounce
	if p.bounce {
		// Store a copy of the frame data
		frameCopy := make([]byte, len(data))
		copy(frameCopy, data)
		p.bounceFrames = append(p.bounceFrames, frameCopy)
	}

	return nil
}

// Draw renders the current frame to the provided SDL2 renderer with letter boxing.
func (p *Player) Draw(renderer *sdl.Renderer, screenWidth, screenHeight int32) error {
	p.m.Lock()
	texture := p.texture
	p.m.Unlock()

	if texture == nil {
		return nil
	}

	// Calculate letterboxing
	videoWidth := int32(p.dec.width)
	videoHeight := int32(p.dec.height)

	scaleW := float64(screenWidth) / float64(videoWidth)
	scaleH := float64(screenHeight) / float64(videoHeight)
	scale := scaleW
	if scaleH < scaleW {
		scale = scaleH
	}

	renderWidth := int32(float64(videoWidth) * scale)
	renderHeight := int32(float64(videoHeight) * scale)

	dstRect := sdl.Rect{
		X: (screenWidth - renderWidth) / 2,
		Y: (screenHeight - renderHeight) / 2,
		W: renderWidth,
		H: renderHeight,
	}

	return renderer.Copy(texture, nil, &dstRect)
}

// Close cleans up resources.
func (p *Player) Close() error {
	p.closeOnce.Do(func() {
		if p.texture != nil {
			p.texture.Destroy()
		}
		if p.dec != nil {
			p.dec.close()
		}
		if p.src != nil {
			_ = p.src.Close()
		}
	})
	return nil
}

// restartLocked seeks to the beginning of the source and reinitializes the decoder.
// p.m must be held when calling.
func (p *Player) restartLocked() error {
	seeker, ok := p.src.(io.Seeker)
	if !ok {
		return fmt.Errorf("source is not seekable; cannot loop")
	}
	if _, err := seeker.Seek(0, io.SeekStart); err != nil {
		return err
	}

	// Close previous decoder and recreate
	if p.dec != nil {
		p.dec.close()
	}

	file, ok := p.src.(*os.File)
	if !ok {
		return fmt.Errorf("src is not *os.File; cannot restart")
	}

	dec, err := newVideoDecoder(file.Name())
	if err != nil {
		return err
	}
	p.dec = dec

	// Recreate texture with new dimensions
	if p.texture != nil {
		p.texture.Destroy()
	}
	if p.renderer != nil {
		p.texture, err = p.renderer.CreateTexture(uint32(sdl.PIXELFORMAT_RGBA32), sdl.TEXTUREACCESS_STREAMING, int32(dec.width), int32(dec.height))
		if err != nil {
			return fmt.Errorf("failed to recreate texture: %v", err)
		}
	}

	// Decode and upload the very first frame right away
	firstFrame, err := p.dec.nextFrame()
	if err != nil {
		return err
	}
	if err := p.updateTexture(firstFrame); err != nil {
		return err
	}

	// Reset playback counters so that timing resumes smoothly from the start.
	p.acc = 0
	p.lastTime = time.Now()

	return nil
}

// FPS returns the stream's frames-per-second estimate.
func (p *Player) FPS() float64 {
	p.m.Lock()
	defer p.m.Unlock()
	return p.dec.fps
}
