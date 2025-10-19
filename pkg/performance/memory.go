package performance

import (
	"log"
	"runtime"
	"time"
)

// MemorySnapshot represents memory state at a point in time
type MemorySnapshot struct {
	Timestamp   time.Time
	TotalMB     uint64 // Total system memory
	AvailableMB uint64 // Available memory for use
	UsedMB      uint64 // Currently used memory
	FreeMB      uint64 // Free memory (not including buffers/cache)
}

// GetAvailableMemoryMB returns only the available memory in MB
func GetAvailableMemoryMB() uint64 {
	snapshot := GetSystemMemory()
	return snapshot.AvailableMB
}

// GetGoMemoryStats returns Go runtime memory statistics
type GoMemoryStats struct {
	AllocMB      uint64 // Currently allocated heap memory
	TotalAllocMB uint64 // Cumulative allocated memory
	SysMB        uint64 // Memory obtained from system
	NumGC        uint32 // Number of GC runs
}

// GetGoMemory retrieves Go runtime memory statistics
func GetGoMemory() GoMemoryStats {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)

	return GoMemoryStats{
		AllocMB:      m.Alloc / (1024 * 1024),
		TotalAllocMB: m.TotalAlloc / (1024 * 1024),
		SysMB:        m.Sys / (1024 * 1024),
		NumGC:        m.NumGC,
	}
}

// IsLowMemory returns true if available memory is below threshold
func IsLowMemory(thresholdMB uint64) bool {
	available := GetAvailableMemoryMB()
	return available < thresholdMB
}

// MemoryPressureLevel represents how much memory pressure the system is under
type MemoryPressureLevel int

const (
	MemoryPressureNone MemoryPressureLevel = iota // >800MB available
	MemoryPressureLow                              // 400-800MB available
	MemoryPressureMedium                           // 200-400MB available
	MemoryPressureHigh                             // 100-200MB available
	MemoryPressureCritical                         // <100MB available
)

// GetMemoryPressure returns the current memory pressure level
func GetMemoryPressure() MemoryPressureLevel {
	available := GetAvailableMemoryMB()

	switch {
	case available < 100:
		return MemoryPressureCritical
	case available < 200:
		return MemoryPressureHigh
	case available < 400:
		return MemoryPressureMedium
	case available < 800:
		return MemoryPressureLow
	default:
		return MemoryPressureNone
	}
}

// String returns a human-readable description of memory pressure
func (m MemoryPressureLevel) String() string {
	switch m {
	case MemoryPressureNone:
		return "None"
	case MemoryPressureLow:
		return "Low"
	case MemoryPressureMedium:
		return "Medium"
	case MemoryPressureHigh:
		return "High"
	case MemoryPressureCritical:
		return "Critical"
	default:
		return "Unknown"
	}
}

// LogMemorySnapshot logs a detailed memory snapshot
func LogMemorySnapshot() {
	sys := GetSystemMemory()
	goMem := GetGoMemory()
	pressure := GetMemoryPressure()

	log.Printf("Memory: System[Total=%dMB, Avail=%dMB, Used=%dMB, Free=%dMB] Go[Alloc=%dMB, Sys=%dMB, GC=%d] Pressure=%s",
		sys.TotalMB, sys.AvailableMB, sys.UsedMB, sys.FreeMB,
		goMem.AllocMB, goMem.SysMB, goMem.NumGC,
		pressure.String())
}
