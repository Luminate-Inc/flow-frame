//go:build darwin
// +build darwin

package performance

import (
	"log"
	"runtime"
	"time"
)

// GetSystemMemory retrieves current system memory information on macOS
// Uses Go runtime stats as syscall.Sysinfo is not available on Darwin
func GetSystemMemory() MemorySnapshot {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)

	// On macOS, we use Go's runtime stats as approximation
	// This gives us process memory, not system-wide, but it's useful for monitoring
	allocMB := m.Alloc / (1024 * 1024)
	sysMB := m.Sys / (1024 * 1024)

	// Rough approximation: assume system has 2GB total for Radxa Zero
	// In production on actual device, this would use sysctl or vm_stat
	totalMB := uint64(2048) // 2GB
	usedMB := sysMB
	freeMB := totalMB - usedMB
	availableMB := freeMB

	if availableMB > totalMB {
		availableMB = totalMB / 2 // Fallback to 50% available
	}

	log.Printf("GetSystemMemory[Darwin]: Using Go runtime stats (approximation). Alloc=%dMB Sys=%dMB",
		allocMB, sysMB)

	return MemorySnapshot{
		Timestamp:   time.Now(),
		TotalMB:     totalMB,
		AvailableMB: availableMB,
		UsedMB:      usedMB,
		FreeMB:      freeMB,
	}
}
