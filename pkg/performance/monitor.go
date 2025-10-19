package performance

import (
	"sync"
	"time"
)

// RollingAverage maintains a rolling average of durations over a fixed window
type RollingAverage struct {
	samples    []time.Duration
	maxSamples int
	sum        time.Duration
	index      int
	filled     bool
	mu         sync.RWMutex
}

// NewRollingAverage creates a rolling average tracker with specified window size
func NewRollingAverage(windowSize int) *RollingAverage {
	return &RollingAverage{
		samples:    make([]time.Duration, windowSize),
		maxSamples: windowSize,
	}
}

// Add records a new sample and updates the rolling average
func (r *RollingAverage) Add(d time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()

	// Subtract old value if we're overwriting
	if r.filled {
		r.sum -= r.samples[r.index]
	}

	// Add new value
	r.samples[r.index] = d
	r.sum += d

	// Advance index
	r.index++
	if r.index >= r.maxSamples {
		r.index = 0
		r.filled = true
	}
}

// Average returns the current rolling average
func (r *RollingAverage) Average() time.Duration {
	r.mu.RLock()
	defer r.mu.RUnlock()

	if !r.filled && r.index == 0 {
		return 0 // No samples yet
	}

	count := r.index
	if r.filled {
		count = r.maxSamples
	}

	if count == 0 {
		return 0
	}

	return r.sum / time.Duration(count)
}

// Count returns the number of samples currently tracked
func (r *RollingAverage) Count() int {
	r.mu.RLock()
	defer r.mu.RUnlock()

	if r.filled {
		return r.maxSamples
	}
	return r.index
}

// Reset clears all samples
func (r *RollingAverage) Reset() {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.sum = 0
	r.index = 0
	r.filled = false
	r.samples = make([]time.Duration, r.maxSamples)
}

// PerformanceMonitor tracks video playback performance metrics
type PerformanceMonitor struct {
	frameDecodeTimes *RollingAverage
	frameRenderTimes *RollingAverage
	totalFrameTime   *RollingAverage
	droppedFrames    int
	totalFrames      int
	startTime        time.Time
	mu               sync.RWMutex
}

// PerformanceReport contains aggregated performance metrics
type PerformanceReport struct {
	AvgDecodeMs       float64 // Average decode time in milliseconds
	AvgRenderMs       float64 // Average render time in milliseconds
	AvgTotalMs        float64 // Average total frame time in milliseconds
	DropRate          float64 // Percentage of dropped frames
	TotalFrames       int     // Total frames processed
	DroppedFrames     int     // Total frames dropped
	IsHealthy         bool    // True if performance is good (no drops, good timing)
	UptimeSeconds     int64   // Seconds since monitor started
}

// NewMonitor creates a new performance monitor
// windowSize determines how many frames to average (120 = 2 seconds at 60fps)
func NewMonitor(windowSize int) *PerformanceMonitor {
	return &PerformanceMonitor{
		frameDecodeTimes: NewRollingAverage(windowSize),
		frameRenderTimes: NewRollingAverage(windowSize),
		totalFrameTime:   NewRollingAverage(windowSize),
		startTime:        time.Now(),
	}
}

// RecordFrameDecode records the time taken to decode a frame
func (p *PerformanceMonitor) RecordFrameDecode(duration time.Duration) {
	p.mu.Lock()
	defer p.mu.Unlock()

	p.frameDecodeTimes.Add(duration)
	p.totalFrames++
}

// RecordFrameRender records the time taken to render a frame
func (p *PerformanceMonitor) RecordFrameRender(duration time.Duration) {
	p.mu.Lock()
	defer p.mu.Unlock()

	p.frameRenderTimes.Add(duration)
}

// RecordTotalFrameTime records the total time for decode + render
func (p *PerformanceMonitor) RecordTotalFrameTime(duration time.Duration) {
	p.mu.Lock()
	defer p.mu.Unlock()

	p.totalFrameTime.Add(duration)
}

// RecordFrameDropped increments the dropped frame counter
func (p *PerformanceMonitor) RecordFrameDropped() {
	p.mu.Lock()
	defer p.mu.Unlock()

	p.droppedFrames++
	p.totalFrames++
}

// GetReport generates a performance report with current metrics
func (p *PerformanceMonitor) GetReport() PerformanceReport {
	p.mu.RLock()
	defer p.mu.RUnlock()

	avgDecode := p.frameDecodeTimes.Average()
	avgRender := p.frameRenderTimes.Average()
	avgTotal := p.totalFrameTime.Average()

	dropRate := 0.0
	if p.totalFrames > 0 {
		dropRate = (float64(p.droppedFrames) / float64(p.totalFrames)) * 100.0
	}

	// Performance is healthy if:
	// - Drop rate < 1%
	// - Average total frame time < 33ms (30fps target)
	isHealthy := dropRate < 1.0 && avgTotal.Milliseconds() < 33

	return PerformanceReport{
		AvgDecodeMs:   float64(avgDecode.Microseconds()) / 1000.0,
		AvgRenderMs:   float64(avgRender.Microseconds()) / 1000.0,
		AvgTotalMs:    float64(avgTotal.Microseconds()) / 1000.0,
		DropRate:      dropRate,
		TotalFrames:   p.totalFrames,
		DroppedFrames: p.droppedFrames,
		IsHealthy:     isHealthy,
		UptimeSeconds: int64(time.Since(p.startTime).Seconds()),
	}
}

// IsPerformanceDegrading returns true if performance metrics indicate problems
func (p *PerformanceMonitor) IsPerformanceDegrading() bool {
	report := p.GetReport()

	// Performance is degrading if:
	// - Drop rate > 5%
	// - Average decode time > 30ms (too slow)
	// - Average total time > 40ms (missing 30fps target by a lot)
	return report.DropRate > 5.0 ||
	       report.AvgDecodeMs > 30.0 ||
	       report.AvgTotalMs > 40.0
}

// Reset clears all performance metrics
func (p *PerformanceMonitor) Reset() {
	p.mu.Lock()
	defer p.mu.Unlock()

	p.frameDecodeTimes.Reset()
	p.frameRenderTimes.Reset()
	p.totalFrameTime.Reset()
	p.droppedFrames = 0
	p.totalFrames = 0
	p.startTime = time.Now()
}
