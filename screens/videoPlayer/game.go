package videoPlayer

import (
	"errors"
	"log"
	"os"
	"time"

	"art-frame/pkg/mpeg"
	"art-frame/pkg/sharedTypes"
	"art-frame/pkg/videoFs"

	"github.com/veandco/go-sdl2/sdl"
)

const prefetchBuffer = 2 // number of videos to keep pre-downloaded

// clearDownloadedVideos removes all video files from the assets/videos directory
func clearDownloadedVideos() {
	entries, err := os.ReadDir("assets/videos")
	if err != nil {
		log.Printf("clearDownloadedVideos: failed to read assets/videos: %v", err)
		return
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			videoPath := "assets/videos/" + entry.Name()
			if err := os.Remove(videoPath); err != nil {
				log.Printf("clearDownloadedVideos: failed to remove %s: %v", videoPath, err)
			}
		}
	}
}

// NewVideoPlayerGame creates and initializes a new video player game
func NewVideoPlayerGame() *VideoPlayerGame {
	// Clean up any existing downloaded videos
	clearDownloadedVideos()

	// Define available video collections matching the UI design
	collections := []sharedTypes.Collection{
		{
			Id:          "1",
			Title:       "Impressionism",
			Description: "Light, color, and fleeting moments.",
			Bucket:      "art-frame",
			Folder:      "calm-abstract",
			BounceLoop:  true,
		},
		{
			Id:          "2",
			Title:       "Abstract",
			Description: "Beyond the tangible world.",
			Bucket:      "art-frame",
			Folder:      "ai-gen",
			BounceLoop:  true,
		},
	}

	// Download initial videos from the first collection
	initialVideos, endOfCollection, err := videoFs.DownloadSegmentFromS3(collections[0], 0, prefetchBuffer)
	if err != nil {
		panic(err)
	}
	if len(initialVideos) == 0 {
		panic("no videos downloaded from S3")
	}

	// Open and initialize the first video
	file, err := os.Open(initialVideos[0])
	if err != nil {
		panic(err)
	}

	player, err := mpeg.NewPlayer(file)
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

	// Create the game instance
	g := &VideoPlayerGame{
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
		prefetchResultCh:    make(chan prefetchResult, 1),
		prefetchPending:     false,
		switchResultCh:      make(chan switchResult, 1),
		switchPending:       false,
	}

	player.Play()
	return g
}

// SetRenderer configures the SDL2 renderer for video rendering
func (g *VideoPlayerGame) SetRenderer(renderer *sdl.Renderer) error {
	g.renderer = renderer
	if g.player != nil {
		return g.player.SetRenderer(renderer)
	}
	return nil
}

// Update processes input and updates video playback state
func (g *VideoPlayerGame) Update(keyState []uint8) error {
	// Update video decoding
	if err := g.player.Update(); err != nil {
		g.err = err
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

	if g.err != nil {
		return g.err
	}
	return nil
}

// handleInput processes SDL2 keyboard input
func (g *VideoPlayerGame) handleInput(keyState []uint8) {
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
func (g *VideoPlayerGame) handleIntervalSwitching() {
	dur := intervalToDuration(g.playbackInterval)
	if dur > 0 && time.Since(g.playStartTime) >= dur {
		log.Printf("Update: switching to next video due to interval")
		g.nextVideo()
	}
}

// handlePrefetchResults processes completed background prefetch operations
func (g *VideoPlayerGame) handlePrefetchResults() {
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
func (g *VideoPlayerGame) handleCollectionSwitching() {
	// Start collection switch if requested
	if g.requestedCollection != g.activeCollection && !g.switchPending {
		g.switchPending = true
		idx := g.requestedCollection
		log.Printf("Update: starting collection download for %s", g.collections[idx].Title)

		go func(collection sharedTypes.Collection, collectionIdx int) {
			vids, end, err := videoFs.DownloadSegmentFromS3(collection, 0, prefetchBuffer)
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
func (g *VideoPlayerGame) Draw(renderer *sdl.Renderer, screenWidth, screenHeight int32) error {
	if g.err != nil {
		return g.err
	}
	if g.player != nil {
		return g.player.Draw(renderer, screenWidth, screenHeight)
	}
	return nil
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
func (g *VideoPlayerGame) nextVideo() {
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

	// Start background prefetch for the next video
	g.startPrefetch()
}

// cleanupCurrentVideo removes the currently playing video from disk and buffer
func (g *VideoPlayerGame) cleanupCurrentVideo() {
	playedPath := g.downloadedVideos[g.currentVideo]

	// Close the current player
	if g.player != nil {
		_ = g.player.Close()
	}

	// Remove the video file
	_ = os.Remove(playedPath)

	// Remove from buffer
	g.downloadedVideos = append(g.downloadedVideos[:g.currentVideo], g.downloadedVideos[g.currentVideo+1:]...)
	g.currentVideo = 0 // Always use index 0 after removal
}

// startNextVideo initializes playback of the next video in the buffer
func (g *VideoPlayerGame) startNextVideo() error {
	nextPath := g.downloadedVideos[g.currentVideo]
	log.Printf("nextVideo: playing %s", nextPath)

	file, err := os.Open(nextPath)
	if err != nil {
		return err
	}

	newPlayer, err := mpeg.NewPlayer(file)
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

	return nil
}

// startPrefetch begins background download of the next video
func (g *VideoPlayerGame) startPrefetch() {
	missing := prefetchBuffer - len(g.downloadedVideos)
	if missing <= 0 || g.prefetchPending {
		return
	}

	g.prefetchPending = true
	collIdx := g.activeCollection
	startIdx := g.nextS3Index

	log.Printf("nextVideo: starting prefetch of %d video(s)", missing)

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
func (g *VideoPlayerGame) SetPlaybackSpeed(speed float64) {
	if speed <= 0 {
		return
	}
	log.Printf("SetPlaybackSpeed: updating to %.2fx", speed)
	g.playbackSpeed = speed
}

// SetPlaybackInterval updates the automatic video switching interval
func (g *VideoPlayerGame) SetPlaybackInterval(label string) {
	log.Printf("SetPlaybackInterval: set to '%s'", label)
	g.playbackInterval = label
}

// SetRequestedCollection requests a switch to a different video collection
func (g *VideoPlayerGame) SetRequestedCollection(idx int) {
	if idx < 0 || idx >= len(g.collections) {
		log.Printf("SetRequestedCollection: invalid index %d", idx)
		return
	}
	log.Printf("SetRequestedCollection: requesting %s", g.collections[idx].Title)
	g.requestedCollection = idx
}

// Collections returns the list of available video collections
func (g *VideoPlayerGame) Collections() []sharedTypes.Collection {
	return g.collections
}

// applyNewCollection switches to a new collection that was downloaded in the background
func (g *VideoPlayerGame) applyNewCollection(idx int, vids []string, endOfCollection bool) error {
	log.Printf("applyNewCollection: switching to %s", g.collections[idx].Title)

	// Stop current playback
	if g.player != nil {
		_ = g.player.Close()
	}

	// Clean up old videos
	for _, p := range g.downloadedVideos {
		_ = os.Remove(p)
	}

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

	player, err := mpeg.NewPlayer(file)
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

	log.Printf("applyNewCollection: switched to %s with %d videos", g.collections[idx].Title, len(vids))
	return nil
}

// PlaybackSpeed returns the current playback speed multiplier
func (g *VideoPlayerGame) PlaybackSpeed() float64 {
	return g.playbackSpeed
}

// PlaybackInterval returns the current interval setting
func (g *VideoPlayerGame) PlaybackInterval() string {
	return g.playbackInterval
}

// IsPrefetchPending returns whether a prefetch operation is currently in progress
func (g *VideoPlayerGame) IsPrefetchPending() bool {
	return g.prefetchPending
}
