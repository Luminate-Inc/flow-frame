//go:build linux
// +build linux

package performance

import (
	"log"
	"syscall"
	"time"
)

// GetSystemMemory retrieves current system memory information on Linux
// Uses syscall.Sysinfo for accurate system-wide memory stats
func GetSystemMemory() MemorySnapshot {
	var info syscall.Sysinfo_t
	err := syscall.Sysinfo(&info)
	if err != nil {
		log.Printf("GetSystemMemory: failed to get sysinfo: %v", err)
		return MemorySnapshot{
			Timestamp: time.Now(),
		}
	}

	// Convert from bytes to MB
	// Sysinfo returns values in units of info.Unit (usually bytes)
	unit := uint64(info.Unit)

	totalMB := (info.Totalram * unit) / (1024 * 1024)
	freeMB := (info.Freeram * unit) / (1024 * 1024)
	bufferMB := (info.Bufferram * unit) / (1024 * 1024)

	// Available memory includes free + buffers (Linux can reclaim buffers)
	availableMB := freeMB + bufferMB
	usedMB := totalMB - availableMB

	return MemorySnapshot{
		Timestamp:   time.Now(),
		TotalMB:     totalMB,
		AvailableMB: availableMB,
		UsedMB:      usedMB,
		FreeMB:      freeMB,
	}
}
