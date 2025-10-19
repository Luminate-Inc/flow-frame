package videoPlayer

import (
	"errors"
	"log"
	"os"
	"runtime"
	"time"

	"flow-frame/pkg/video"
	"flow-frame/pkg/performance"
	"flow-frame/pkg/sharedTypes"
	"flow-frame/pkg/videoFs"

	"github.com/veandco/go-sdl2/sdl"
)

// calculatePrefetchBuffer determines optimal prefetch count based on available memory
// Conservative approach: only prefetch when we have sufficient RAM
func calculatePrefetchBuffer() int {
	memInfo := performance.GetSystemMemory()
	availMB := memInfo.AvailableMB

	// Very conservative thresholds for 2GB device
	// Each video ~200MB, so be careful
	switch {
	case availMB < 400:
		// Critical memory pressure - no prefetch
		log.Printf("calculatePrefetchBuffer: Low memory (%dMB avail) - disabling prefetch", availMB)
		return 0

	case availMB < 700:
		// Medium pressure - minimal prefetch
		log.Printf("calculatePrefetchBuffer: Medium memory (%dMB avail) - prefetch 1 video", availMB)
		return 1

	case availMB < 1000:
		// Comfortable - standard prefetch
		return 2

	default:
		// Plenty of RAM - aggressive prefetch
		return 3
	}
}

// getPrefetchBuffer returns current prefetch buffer size (always recalculate for dynamic adjustment)
func getPrefetchBuffer() int {
	return calculatePrefetchBuffer()
}

// clearDownloadedVideos removes all video files from the assets/tmp directory
func clearDownloadedVideos() {
	entries, err := os.ReadDir("assets/tmp")
	if err != nil {
		log.Printf("clearDownloadedVideos: failed to read assets/tmp: %v", err)
		return
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			videoPath := "assets/tmp/" + entry.Name()
			if err := os.Remove(videoPath); err != nil {
				log.Printf("clearDownloadedVideos: failed to remove %s: %v", videoPath, err)
			}
		}
	}
}

// NewVideoPlayerScreen creates and initializes a new video player screen
func NewVideoPlayerScreen() *VideoPlayerScreen {
	// Clean up any existing downloaded videos
	clearDownloadedVideos()

	// Define available video collections matching the UI design
	collections := []sharedTypes.Collection{
		{
			Id:          "1",
			Title:       "Impressionism",
			Description: "Light, color, and fleeting moments.",
			Bucket:      "flow-frame",
			Folder:      "calm-abstract",
			BounceLoop:  true,
		},
		{
			Id:          "2",
			Title:       "Abstract",
			Description: "Beyond the tangible world.",
			Bucket:      "flow-frame",
			Folder:      "ai-gen",
			BounceLoop:  true,
		},
	}

	// Download initial videos from the first collection
	// Use dynamic prefetch based on available memory
	initialPrefetch := getPrefetchBuffer()
	if initialPrefetch == 0 {
		initialPrefetch = 1 // Always download at least 1 video to start
	}
	log.Printf("NewVideoPlayerScreen: Initial prefetch count = %d", initialPrefetch)

	initialVideos, endOfCollection, err := videoFs.DownloadSegmentFromS3(collections[0], 0, initialPrefetch)
	if err != nil || len(initialVideos) == 0 {
		// Fall back to checking whats pre existing
		initialVideos, err = videoFs.AvailableDownloadedVideos()
	}

	// Open and initialize the first video
	file, err := os.Open(initialVideos[0])
	if err != nil {
		panic(err)
	}

	player, err := video.NewPlayer(file)
	if err != nil {
		panic(err)
	}

	// Configure player settings based on collection metadata
	player.SetBounceLoop(collections[0].BounceLoop)

	// Set up S3 index for future downloads
	var nextS3Index int
	if endOfCollection {
		nextS3Index = 0
	} else {
		nextS3Index = len(initialVideos)
	}

	// Create the screen instance
	g := &VideoPlayerScreen{
		player:              player,
		downloadedVideos:    initialVideos,
		playbackSpeed:       1.0,          // normal speed
		playbackInterval:    "Every hour", // default interval
		activeCollection:    0,
		requestedCollection: 0,
		collections:         collections,
		nextS3Index:         nextS3Index,
		currentVideo:        0,
		playStartTime:       time.Now(),
		perfMonitor:         performance.NewMonitor(120), // Track last 120 frames (2 seconds at 60fps)
		frameSkipper:        video.NewFrameSkipper(),      // Adaptive frame skip logic
		prefetchResultCh:    make(chan prefetchResult, 1),
		prefetchPending:     false,
		switchResultCh:      make(chan switchResult, 1),
		switchPending:       false,
	}

	player.Play()
	return g
}

// SetRenderer configures the SDL2 renderer for video rendering
func (g *VideoPlayerScreen) SetRenderer(renderer *sdl.Renderer) error {
	g.renderer = renderer

	// Log renderer information for debugging
	if renderer != nil {
		info, err := renderer.GetInfo()
		if err == nil {
			isAccelerated := (info.Flags & sdl.RENDERER_ACCELERATED) != 0
			hasVSync := (info.Flags & sdl.RENDERER_PRESENTVSYNC) != 0

			accelStatus := "software"
			if isAccelerated {
				accelStatus = "hardware"
			}

			log.Printf("Renderer: %s (accelerated=%s, vsync=%v, maxTexture=%dx%d)",
				info.Name, accelStatus, hasVSync,
				info.MaxTextureWidth, info.MaxTextureHeight)
		}

		// Log initial memory state
		performance.LogMemorySnapshot()
	}

	if g.player != nil {
		return g.player.SetRenderer(renderer)
	}
	return nil
}

// Update processes input and updates video playback state
func (g *VideoPlayerScreen) Update(keyState []uint8) error {
	// Track total frame time
	frameStart := time.Now()

	// Get skip decision from frame skipper based on recent performance
	decision := g.frameSkipper.ShouldDecode(g.perfMonitor.GetReport())

	// Conditionally decode based on performance
	if decision.ShouldDecode {
		// Decode new frame
		decodeStart := time.Now()
		if err := g.player.Update(); err != nil {
			g.err = err
		}
		decodeTime := time.Since(decodeStart)
		g.perfMonitor.RecordFrameDecode(decodeTime)
	} else {
		// Skip decode - GPU will render last decoded frame
		// This maintains smooth 60fps render with reduced decode rate
		g.perfMonitor.RecordFrameDropped()
	}

	// Handle input - right arrow to skip to next video
	g.handleInput(keyState)

	// Apply current playback speed
	g.player.SetPlaybackRate(g.playbackSpeed)

	// Handle automatic video switching based on interval
	g.handleIntervalSwitching()

	// Process background prefetch operations
	g.handlePrefetchResults()

	// Process collection switching
	g.handleCollectionSwitching()

	// Record total frame time (will add render time in Draw)
	totalFrameTime := time.Since(frameStart)
	g.perfMonitor.RecordTotalFrameTime(totalFrameTime)

	// Log performance metrics periodically
	g.logPerformanceMetrics()

	if g.err != nil {
		return g.err
	}
	return nil
}

// handleInput processes SDL2 keyboard input
func (g *VideoPlayerScreen) handleInput(keyState []uint8) {
	// Skip input handling if keyState is nil (when UI popup is active)
	if keyState == nil {
		g.rightKeyPressed = false
		return
	}

	// Right arrow key to skip to next video
	if keyState[sdl.SCANCODE_RIGHT] != 0 {
		if !g.rightKeyPressed {
			g.nextVideo()
			g.rightKeyPressed = true
		}
	} else {
		g.rightKeyPressed = false
	}
}

// handleIntervalSwitching checks if it's time to switch videos based on the interval setting
func (g *VideoPlayerScreen) handleIntervalSwitching() {
	dur := intervalToDuration(g.playbackInterval)
	if dur > 0 && time.Since(g.playStartTime) >= dur {
		log.Printf("Update: switching to next video due to interval")
		g.nextVideo()
	}
}

// handlePrefetchResults processes completed background prefetch operations
func (g *VideoPlayerScreen) handlePrefetchResults() {
	select {
	case res := <-g.prefetchResultCh:
		if res.err != nil {
			g.err = res.err
		} else if res.collectionIdx == g.activeCollection {
			if len(res.vids) > 0 {
				g.downloadedVideos = append(g.downloadedVideos, res.vids...)
				g.nextS3Index += len(res.vids)
				log.Printf("prefetch: appended %d video(s) to buffer", len(res.vids))
			}
			if res.endOfCollection {
				g.nextS3Index = 0
				log.Printf("prefetch: reached end of collection - will wrap to start")
			}
		} else {
			log.Printf("prefetch: discarding outdated results for collection %d", res.collectionIdx)
		}
		g.prefetchPending = false

		// Process any queued nextVideo calls
		for g.queuedNextCalls > 0 && !g.prefetchPending {
			g.queuedNextCalls--
			g.nextVideo()
		}
	default:
		// No prefetch results available
	}
}

// handleCollectionSwitching manages background collection downloads and switches
func (g *VideoPlayerScreen) handleCollectionSwitching() {
	// Start collection switch if requested
	if g.requestedCollection != g.activeCollection && !g.switchPending {
		g.switchPending = true
		idx := g.requestedCollection
		log.Printf("Update: starting collection download for %s", g.collections[idx].Title)

		go func(collection sharedTypes.Collection, collectionIdx int) {
			// Use dynamic prefetch for collection switch
			prefetchCount := getPrefetchBuffer()
			if prefetchCount == 0 {
				prefetchCount = 1 // Always download at least 1 video
			}
			vids, end, err := videoFs.DownloadSegmentFromS3(collection, 0, prefetchCount)
			g.switchResultCh <- switchResult{
				vids:            vids,
				endOfCollection: end,
				err:             err,
				collectionIdx:   collectionIdx,
			}
		}(g.collections[idx], idx)
	}

	// Process completed collection switches
	select {
	case sw := <-g.switchResultCh:
		if sw.err != nil {
			g.err = sw.err
		} else if sw.collectionIdx != g.requestedCollection {
			log.Printf("switch: discarding outdated results for collection %d", sw.collectionIdx)
		} else if len(sw.vids) == 0 {
			g.err = errors.New("no videos downloaded from S3 for new collection")
		} else {
			if err := g.applyNewCollection(sw.collectionIdx, sw.vids, sw.endOfCollection); err != nil {
				g.err = err
			}
		}
		g.switchPending = false
	default:
		// No switch results available
	}
}

// Draw renders the current video frame using SDL2
func (g *VideoPlayerScreen) Draw(renderer *sdl.Renderer, screenWidth, screenHeight int32) error {
	if g.err != nil {
		return g.err
	}

	// Track render time
	renderStart := time.Now()
	var err error
	if g.player != nil {
		err = g.player.Draw(renderer, screenWidth, screenHeight)
	}
	renderTime := time.Since(renderStart)
	g.perfMonitor.RecordFrameRender(renderTime)

	return err
}

// intervalToDuration converts interval strings to time.Duration
func intervalToDuration(label string) time.Duration {
	switch label {
	case "Every minute":
		return time.Minute
	case "Every hour":
		return time.Hour
	case "Every 12 hours":
		return 12 * time.Hour
	case "Every day":
		return 24 * time.Hour
	case "Every week":
		return 7 * 24 * time.Hour
	default:
		return time.Hour
	}
}

// nextVideo advances to the next video in the queue
func (g *VideoPlayerScreen) nextVideo() {
	// Queue request if prefetch is in progress
	if g.prefetchPending {
		g.queuedNextCalls = 1
		log.Printf("nextVideo: prefetch pending, queued request")
		return
	}

	// Clear any previous errors
	g.err = nil

	if len(g.downloadedVideos) == 0 {
		log.Printf("nextVideo: no videos in buffer")
		return
	}

	// Clean up the current video
	g.cleanupCurrentVideo()

	// Advance to next video
	if len(g.downloadedVideos) == 0 {
		g.err = errors.New("buffer unexpectedly empty after cleanup")
		return
	}

	// Start playing the next video
	if err := g.startNextVideo(); err != nil {
		g.err = err
		return
	}

	// Reset frame skipper for new video (fresh performance profile)
	g.frameSkipper.Reset()

	// Start background prefetch for the next video
	g.startPrefetch()
}

// cleanupCurrentVideo removes the currently playing video from disk and buffer
// Performs aggressive cleanup to free memory immediately
func (g *VideoPlayerScreen) cleanupCurrentVideo() {
	playedPath := g.downloadedVideos[g.currentVideo]

	// Log memory before cleanup
	memBefore := performance.GetSystemMemory()

	// Close the current player (frees decoder resources)
	if g.player != nil {
		_ = g.player.Close()
		g.player = nil // Ensure GC can collect
	}

	// Remove the video file from disk
	if err := os.Remove(playedPath); err != nil {
		log.Printf("cleanupCurrentVideo: failed to remove %s: %v", playedPath, err)
	} else {
		log.Printf("cleanupCurrentVideo: removed %s", playedPath)
	}

	// Remove from buffer
	g.downloadedVideos = append(g.downloadedVideos[:g.currentVideo], g.downloadedVideos[g.currentVideo+1:]...)
	g.currentVideo = 0 // Always use index 0 after removal

	// Hint to GC that now is a good time to run
	// This is just a hint - GC will decide based on its own heuristics
	runtime.GC()

	// Log memory after cleanup
	memAfter := performance.GetSystemMemory()
	freed := int64(memAfter.AvailableMB) - int64(memBefore.AvailableMB)
	log.Printf("cleanupCurrentVideo: freed ~%dMB (avail: %dMB → %dMB)",
		freed, memBefore.AvailableMB, memAfter.AvailableMB)
}

// startNextVideo initializes playback of the next video in the buffer
func (g *VideoPlayerScreen) startNextVideo() error {
	nextPath := g.downloadedVideos[g.currentVideo]
	log.Printf("nextVideo: playing %s", nextPath)

	file, err := os.Open(nextPath)
	if err != nil {
		return err
	}

	newPlayer, err := video.NewPlayer(file)
	if err != nil {
		return err
	}

	// Configure player settings
	newPlayer.SetBounceLoop(g.collections[g.activeCollection].BounceLoop)

	// Set up SDL2 renderer
	if g.renderer != nil {
		if err := newPlayer.SetRenderer(g.renderer); err != nil {
			return err
		}
	}

	// Start playback
	g.player = newPlayer
	g.player.Play()
	g.playStartTime = time.Now()

	// Log codec information for the new video
	info := g.player.GetCodecInfo()
	log.Printf("Video: %s | Codec: %s [HW=%v] | %dx%d @ %.1ffps",
		nextPath, info.Name, info.IsHardwareAccel, info.Width, info.Height, info.FPS)

	return nil
}

// startPrefetch begins background download of the next video
func (g *VideoPlayerScreen) startPrefetch() {
	if g.prefetchPending {
		return
	}

	// Dynamic prefetch buffer based on current memory availability
	targetBuffer := getPrefetchBuffer()
	missing := targetBuffer - len(g.downloadedVideos)

	if missing <= 0 {
		return
	}

	// Check memory pressure before starting download
	memInfo := performance.GetSystemMemory()
	pressure := performance.GetMemoryPressure()

	// Don't prefetch if memory is critical or high pressure
	if pressure >= performance.MemoryPressureHigh {
		log.Printf("startPrefetch: Skipping prefetch due to %s memory pressure (%dMB available)",
			pressure.String(), memInfo.AvailableMB)
		return
	}

	// Warn if downloading under medium pressure
	if pressure == performance.MemoryPressureMedium {
		log.Printf("startPrefetch: Prefetching %d video(s) under medium memory pressure (%dMB available)",
			missing, memInfo.AvailableMB)
	}

	g.prefetchPending = true
	collIdx := g.activeCollection
	startIdx := g.nextS3Index

	log.Printf("startPrefetch: Downloading %d video(s) [buffer=%d, avail=%dMB, pressure=%s]",
		missing, targetBuffer, memInfo.AvailableMB, pressure.String())

	go func(collection sharedTypes.Collection, collectionIdx, start, count int) {
		vids, end, err := videoFs.DownloadSegmentFromS3(collection, start, count)
		g.prefetchResultCh <- prefetchResult{
			vids:            vids,
			endOfCollection: end,
			err:             err,
			collectionIdx:   collectionIdx,
		}
	}(g.collections[collIdx], collIdx, startIdx, missing)
}

// SetPlaybackSpeed updates the video playback speed
func (g *VideoPlayerScreen) SetPlaybackSpeed(speed float64) {
	if speed <= 0 {
		return
	}
	log.Printf("SetPlaybackSpeed: updating to %.2fx", speed)
	g.playbackSpeed = speed
}

// SetPlaybackInterval updates the automatic video switching interval
func (g *VideoPlayerScreen) SetPlaybackInterval(label string) {
	log.Printf("SetPlaybackInterval: set to '%s'", label)
	g.playbackInterval = label
}

// SetRequestedCollection requests a switch to a different video collection
func (g *VideoPlayerScreen) SetRequestedCollection(idx int) {
	if idx < 0 || idx >= len(g.collections) {
		log.Printf("SetRequestedCollection: invalid index %d", idx)
		return
	}
	log.Printf("SetRequestedCollection: requesting %s", g.collections[idx].Title)
	g.requestedCollection = idx
}

// Collections returns the list of available video collections
func (g *VideoPlayerScreen) Collections() []sharedTypes.Collection {
	return g.collections
}

// applyNewCollection switches to a new collection that was downloaded in the background
func (g *VideoPlayerScreen) applyNewCollection(idx int, vids []string, endOfCollection bool) error {
	log.Printf("applyNewCollection: switching to %s", g.collections[idx].Title)

	// Log memory before cleanup
	memBefore := performance.GetSystemMemory()

	// Stop current playback
	if g.player != nil {
		_ = g.player.Close()
		g.player = nil // Ensure GC can collect
	}

	// Clean up old videos aggressively
	removedCount := 0
	for _, p := range g.downloadedVideos {
		if err := os.Remove(p); err == nil {
			removedCount++
		}
	}
	log.Printf("applyNewCollection: removed %d old video(s)", removedCount)

	// Update state with new collection
	g.downloadedVideos = vids
	g.currentVideo = 0
	g.activeCollection = idx

	if endOfCollection {
		g.nextS3Index = 0
	} else {
		g.nextS3Index = len(vids)
	}

	// Start playing the first video of the new collection
	file, err := os.Open(vids[0])
	if err != nil {
		return err
	}

	player, err := video.NewPlayer(file)
	if err != nil {
		return err
	}

	// Configure new player
	player.SetBounceLoop(g.collections[idx].BounceLoop)

	if g.renderer != nil {
		if err := player.SetRenderer(g.renderer); err != nil {
			return err
		}
	}

	// Start playback
	g.player = player
	g.playStartTime = time.Now()
	g.player.Play()

	// Reset frame skipper for new collection (fresh performance profile)
	g.frameSkipper.Reset()

	// Hint to GC to clean up old collection resources
	runtime.GC()

	// Log memory after collection switch
	memAfter := performance.GetSystemMemory()
	freed := int64(memAfter.AvailableMB) - int64(memBefore.AvailableMB)
	log.Printf("applyNewCollection: switched to %s with %d videos, freed ~%dMB (avail: %dMB → %dMB)",
		g.collections[idx].Title, len(vids), freed, memBefore.AvailableMB, memAfter.AvailableMB)

	return nil
}

// PlaybackSpeed returns the current playback speed multiplier
func (g *VideoPlayerScreen) PlaybackSpeed() float64 {
	return g.playbackSpeed
}

// PlaybackInterval returns the current interval setting
func (g *VideoPlayerScreen) PlaybackInterval() string {
	return g.playbackInterval
}

// IsPrefetchPending returns whether a prefetch operation is currently in progress
func (g *VideoPlayerScreen) IsPrefetchPending() bool {
	return g.prefetchPending
}

// logPerformanceMetrics logs performance and memory stats periodically
func (g *VideoPlayerScreen) logPerformanceMetrics() {
	now := time.Now()

	// Log performance stats every 5 seconds
	if now.Sub(g.lastPerfLog) >= 5*time.Second {
		report := g.perfMonitor.GetReport()
		skipMode := g.frameSkipper.GetMode()

		healthStatus := "OK"
		if !report.IsHealthy {
			healthStatus = "DEGRADED"
		}
		if g.perfMonitor.IsPerformanceDegrading() {
			healthStatus = "WARNING"
		}

		log.Printf("Performance[%s]: Decode=%.2fms Render=%.2fms Total=%.2fms Frames=%d Drops=%d (%.1f%%) Mode=%s Uptime=%ds",
			healthStatus,
			report.AvgDecodeMs,
			report.AvgRenderMs,
			report.AvgTotalMs,
			report.TotalFrames,
			report.DroppedFrames,
			report.DropRate,
			skipMode.String(),
			report.UptimeSeconds)

		g.lastPerfLog = now
	}

	// Log memory stats every 10 seconds
	if now.Sub(g.lastMemoryLog) >= 10*time.Second {
		performance.LogMemorySnapshot()
		g.lastMemoryLog = now
	}
}

// GetPerformanceReport returns current performance metrics
func (g *VideoPlayerScreen) GetPerformanceReport() performance.PerformanceReport {
	return g.perfMonitor.GetReport()
}

// IsPerformanceDegrading returns true if performance is degrading
func (g *VideoPlayerScreen) IsPerformanceDegrading() bool {
	return g.perfMonitor.IsPerformanceDegrading()
}

// ResetPerformanceMetrics resets all performance tracking
func (g *VideoPlayerScreen) ResetPerformanceMetrics() {
	g.perfMonitor.Reset()
	log.Printf("Performance metrics reset")
}

// GetFrameSkipMode returns the current frame skip mode
func (g *VideoPlayerScreen) GetFrameSkipMode() video.SkipMode {
	return g.frameSkipper.GetMode()
}

// GetFrameSkipStats returns current frame skipper statistics
func (g *VideoPlayerScreen) GetFrameSkipStats() video.FrameSkipperStats {
	return g.frameSkipper.GetStats()
}

// SetFrameSkipThresholds allows customizing frame skip performance thresholds
// slowMs: decode time threshold for "slow" classification (default 30ms)
// goodMs: decode time threshold for "good" classification (default 20ms)
func (g *VideoPlayerScreen) SetFrameSkipThresholds(slowMs, goodMs float64) {
	g.frameSkipper.SetThresholds(slowMs, goodMs)
}

// GetMemoryStatus returns current system memory status
func (g *VideoPlayerScreen) GetMemoryStatus() performance.MemorySnapshot {
	return performance.GetSystemMemory()
}

// GetMemoryPressure returns current memory pressure level
func (g *VideoPlayerScreen) GetMemoryPressure() performance.MemoryPressureLevel {
	return performance.GetMemoryPressure()
}

// GetPrefetchBufferSize returns the current dynamic prefetch buffer size
func (g *VideoPlayerScreen) GetPrefetchBufferSize() int {
	return getPrefetchBuffer()
}

// GetDownloadedVideoCount returns number of videos currently in buffer
func (g *VideoPlayerScreen) GetDownloadedVideoCount() int {
	return len(g.downloadedVideos)
}

// ForceGarbageCollection manually triggers garbage collection
// Useful for testing or low-memory situations
func (g *VideoPlayerScreen) ForceGarbageCollection() {
	log.Printf("ForceGarbageCollection: Manually triggering GC")
	memBefore := performance.GetSystemMemory()
	runtime.GC()
	memAfter := performance.GetSystemMemory()
	freed := int64(memAfter.AvailableMB) - int64(memBefore.AvailableMB)
	log.Printf("ForceGarbageCollection: freed ~%dMB (avail: %dMB → %dMB)",
		freed, memBefore.AvailableMB, memAfter.AvailableMB)
}

// GetCodecInfo returns detailed information about the current video codec
func (g *VideoPlayerScreen) GetCodecInfo() video.CodecInfo {
	if g.player != nil {
		return g.player.GetCodecInfo()
	}
	return video.CodecInfo{}
}

// IsHardwareAccelerated returns true if hardware decoding is active
func (g *VideoPlayerScreen) IsHardwareAccelerated() bool {
	if g.player != nil {
		return g.player.IsHardwareAccelerated()
	}
	return false
}

// GetCodecRecommendation analyzes current codec and provides optimization recommendations
func (g *VideoPlayerScreen) GetCodecRecommendation() video.CodecRecommendation {
	if g.player != nil {
		info := g.player.GetCodecInfo()
		return video.AnalyzeCodec(info)
	}
	return video.CodecRecommendation{}
}

// LogCodecAnalysis logs detailed codec information and recommendations
func (g *VideoPlayerScreen) LogCodecAnalysis() {
	if g.player == nil {
		log.Printf("LogCodecAnalysis: No player active")
		return
	}

	info := g.player.GetCodecInfo()
	rec := video.AnalyzeCodec(info)

	log.Printf("=== Codec Analysis ===")
	log.Printf("Current: %s [%s] %dx%d @ %.1ffps", info.Name, info.LongName, info.Width, info.Height, info.FPS)
	log.Printf("Hardware Accel: %v", info.IsHardwareAccel)
	log.Printf("Codec Type: %s", rec.CurrentType.String())
	log.Printf("Optimal: %v", rec.IsOptimal)

	if !rec.IsOptimal {
		log.Printf("Recommendation: Switch to %s (%s)", rec.RecommendedCodec, rec.RecommendedType.String())
		log.Printf("Reason: %s", rec.Reason)
		if rec.ExpectedImprovement != "" {
			log.Printf("Expected Improvement: %s", rec.ExpectedImprovement)
		}
		if rec.ReencodingCommand != "" {
			log.Printf("Re-encoding Command:")
			log.Printf("  %s", rec.ReencodingCommand)
		}
	} else {
		log.Printf("Status: Optimal configuration for this device")
	}
	log.Printf("===================")
}
