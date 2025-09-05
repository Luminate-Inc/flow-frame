package videoPlayer

import (
	"time"

	"flow-frame/pkg/mpeg"
	"flow-frame/pkg/sharedTypes"

	"github.com/veandco/go-sdl2/sdl"
)

type VideoPlayerGame struct {
	player *mpeg.Player
	err    error

	// Local video library information
	downloadedVideos    []string // list of available videos
	activeCollection    int      // information about the current collection
	requestedCollection int      // information about the requested collection
	collections         []sharedTypes.Collection
	nextS3Index         int // index of the next video in the collection to download from S3

	// Playback configuration that can be tweaked at runtime via the popup menu.
	playbackSpeed    float64 // multiplier, e.g. 1.0 = normal speed
	playbackInterval string  // human-readable interval label, e.g. "Every hour"

	// Runtime state
	currentVideo  int       // index of the currently playing video
	playStartTime time.Time // wall-clock time when current video (loop) started

	// Background prefetching bookkeeping
	prefetchResultCh chan prefetchResult // channel to receive async prefetch results
	prefetchPending  bool                // true while a prefetch goroutine is running
	queuedNextCalls  int                 // number of nextVideo calls queued while prefetch is pending

	// Background collection switch
	switchResultCh chan switchResult // channel to receive async switch results
	switchPending  bool              // true while a collection-switch download is running

	// SDL2-specific fields
	renderer        *sdl.Renderer // SDL2 renderer for video display
	rightKeyPressed bool          // track right key state to avoid duplicate calls
}

// Struct used to communicate results of background S3 prefetch operations.
type prefetchResult struct {
	vids            []string
	endOfCollection bool
	err             error
	collectionIdx   int
}

// Struct used to communicate results of background collection switch downloads.
type switchResult struct {
	vids            []string
	endOfCollection bool
	err             error
	collectionIdx   int
}
