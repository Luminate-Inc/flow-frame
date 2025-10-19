package video

import (
	"log"
	"sync"
	"time"

	"flow-frame/pkg/performance"
)

// SkipMode represents the current frame skipping strategy
type SkipMode int

const (
	ModeNormal SkipMode = iota // Decode every frame (60fps target)
	ModeSkip2                  // Decode every 2nd frame (30fps effective)
	ModeSkip3                  // Decode every 3rd frame (20fps effective)
)

// String returns human-readable mode name
func (m SkipMode) String() string {
	switch m {
	case ModeNormal:
		return "Normal(60fps)"
	case ModeSkip2:
		return "Skip2(30fps)"
	case ModeSkip3:
		return "Skip3(20fps)"
	default:
		return "Unknown"
	}
}

// FrameSkipper adaptively skips frame decoding based on performance
type FrameSkipper struct {
	mode            SkipMode
	frameCounter    uint64
	consecutiveSlow int
	consecutiveGood int

	// Thresholds for performance classification
	slowThreshold time.Duration // If avg decode time > this, consider "slow"
	goodThreshold time.Duration // If avg decode time < this, consider "good"

	// Hysteresis counters to prevent mode thrashing
	enterSkip2After    int // Consecutive slow frames before entering Skip2
	enterSkip3After    int // Consecutive slow frames in Skip2 before entering Skip3
	exitToNormalAfter  int // Consecutive good frames in Skip2 before returning to Normal
	exitToSkip2After   int // Consecutive good frames in Skip3 before upgrading to Skip2

	mu sync.RWMutex
}

// SkipDecision contains the frame skip decision and reasoning
type SkipDecision struct {
	ShouldDecode bool
	ShouldSkip   bool
	Reason       string
	CurrentMode  SkipMode
}

// NewFrameSkipper creates a new adaptive frame skipper with sensible defaults
func NewFrameSkipper() *FrameSkipper {
	return &FrameSkipper{
		mode:          ModeNormal,
		slowThreshold: 30 * time.Millisecond, // 30ms = too slow for 60fps (16.67ms budget)
		goodThreshold: 20 * time.Millisecond, // 20ms = good performance

		// Hysteresis settings prevent rapid mode switching
		enterSkip2After:    3,  // 3 consecutive slow frames → Skip2
		enterSkip3After:    5,  // 5 consecutive slow frames → Skip3
		exitToNormalAfter:  60, // 60 good frames (1 sec @ 60fps) → Normal
		exitToSkip2After:   30, // 30 good frames (1.5 sec @ 20fps) → Skip2
	}
}

// ShouldDecode returns a decision on whether to decode the next frame
// Call this before player.Update() on each frame
func (f *FrameSkipper) ShouldDecode(report performance.PerformanceReport) SkipDecision {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.frameCounter++

	// Update mode based on recent performance
	f.updateModeLocked(report)

	// Make decision based on current mode
	decision := f.makeDecisionLocked()

	return decision
}

// updateModeLocked analyzes performance and transitions between modes
// Must be called with f.mu held
func (f *FrameSkipper) updateModeLocked(report performance.PerformanceReport) {
	avgDecode := time.Duration(report.AvgDecodeMs * float64(time.Millisecond))

	// Classify current performance
	if avgDecode > f.slowThreshold {
		f.consecutiveSlow++
		f.consecutiveGood = 0
	} else if avgDecode < f.goodThreshold {
		f.consecutiveGood++
		f.consecutiveSlow = 0
	} else {
		// Middle zone - reset counters to prevent premature transitions
		f.consecutiveSlow = 0
		f.consecutiveGood = 0
	}

	// State machine transitions with hysteresis
	switch f.mode {
	case ModeNormal:
		if f.consecutiveSlow >= f.enterSkip2After {
			f.mode = ModeSkip2
			f.consecutiveSlow = 0
			log.Printf("FrameSkipper: Performance degrading, entering Skip2 mode (30fps decode, 60fps render)")
		}

	case ModeSkip2:
		if f.consecutiveSlow >= f.enterSkip3After {
			// Performance still bad, go to more aggressive skipping
			f.mode = ModeSkip3
			f.consecutiveSlow = 0
			log.Printf("FrameSkipper: Performance still degrading, entering Skip3 mode (20fps decode, 60fps render)")
		} else if f.consecutiveGood >= f.exitToNormalAfter {
			// Performance recovered, return to normal
			f.mode = ModeNormal
			f.consecutiveGood = 0
			log.Printf("FrameSkipper: Performance recovered, returning to Normal mode (60fps decode)")
		}

	case ModeSkip3:
		if f.consecutiveGood >= f.exitToSkip2After {
			// Performance improving, upgrade to less aggressive skipping
			f.mode = ModeSkip2
			f.consecutiveGood = 0
			log.Printf("FrameSkipper: Performance improving, upgrading to Skip2 mode (30fps decode)")
		}
	}
}

// makeDecisionLocked creates a skip decision based on current mode and frame counter
// Must be called with f.mu held
func (f *FrameSkipper) makeDecisionLocked() SkipDecision {
	switch f.mode {
	case ModeNormal:
		// Decode every frame
		return SkipDecision{
			ShouldDecode: true,
			ShouldSkip:   false,
			Reason:       "normal:decode_all",
			CurrentMode:  ModeNormal,
		}

	case ModeSkip2:
		// Decode every 2nd frame (30fps effective)
		shouldDecode := f.frameCounter%2 == 0
		reason := "skip2:decode"
		if !shouldDecode {
			reason = "skip2:skip"
		}
		return SkipDecision{
			ShouldDecode: shouldDecode,
			ShouldSkip:   !shouldDecode,
			Reason:       reason,
			CurrentMode:  ModeSkip2,
		}

	case ModeSkip3:
		// Decode every 3rd frame (20fps effective)
		shouldDecode := f.frameCounter%3 == 0
		reason := "skip3:decode"
		if !shouldDecode {
			reason = "skip3:skip"
		}
		return SkipDecision{
			ShouldDecode: shouldDecode,
			ShouldSkip:   !shouldDecode,
			Reason:       reason,
			CurrentMode:  ModeSkip3,
		}
	}

	// Fallback: always decode (safety)
	return SkipDecision{
		ShouldDecode: true,
		ShouldSkip:   false,
		Reason:       "fallback:decode",
		CurrentMode:  f.mode,
	}
}

// Reset returns the frame skipper to initial state (Normal mode)
// Call this when switching videos or collections
func (f *FrameSkipper) Reset() {
	f.mu.Lock()
	defer f.mu.Unlock()

	oldMode := f.mode
	f.mode = ModeNormal
	f.frameCounter = 0
	f.consecutiveSlow = 0
	f.consecutiveGood = 0

	if oldMode != ModeNormal {
		log.Printf("FrameSkipper: Reset to Normal mode")
	}
}

// GetMode returns the current skip mode
func (f *FrameSkipper) GetMode() SkipMode {
	f.mu.RLock()
	defer f.mu.RUnlock()
	return f.mode
}

// GetStats returns current frame skipper statistics
func (f *FrameSkipper) GetStats() FrameSkipperStats {
	f.mu.RLock()
	defer f.mu.RUnlock()

	return FrameSkipperStats{
		Mode:            f.mode,
		FrameCounter:    f.frameCounter,
		ConsecutiveSlow: f.consecutiveSlow,
		ConsecutiveGood: f.consecutiveGood,
	}
}

// FrameSkipperStats contains current state of the frame skipper
type FrameSkipperStats struct {
	Mode            SkipMode
	FrameCounter    uint64
	ConsecutiveSlow int
	ConsecutiveGood int
}

// SetThresholds allows customizing performance thresholds
// Useful for tuning on different hardware
func (f *FrameSkipper) SetThresholds(slowMs, goodMs float64) {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.slowThreshold = time.Duration(slowMs * float64(time.Millisecond))
	f.goodThreshold = time.Duration(goodMs * float64(time.Millisecond))

	log.Printf("FrameSkipper: Thresholds updated (slow>%.1fms, good<%.1fms)", slowMs, goodMs)
}
