package settings

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

var (
	SpeedOptions    = []string{"0.2x", "0.5x", "0.8x", "1x", "2x", "3x"}
	IntervalOptions = []string{"Every minute", "Every hour", "Every 12 hours", "Every day", "Every week"}
)

// BuildMainMenuItems creates the main settings menu items
func BuildMainMenuItems(currentSpeed float64, currentInterval string) []Item {
	return []Item{
		{
			Title: "Playback Speed",
			Value: fmt.Sprintf("%.1fx", currentSpeed),
		},
		{
			Title: "Playback Interval",
			Value: currentInterval,
		},
		{
			Title: "System Settings",
			Value: "Configure system options",
		},
	}
}

// BuildSpeedMenuItems creates the speed selection menu items
func BuildSpeedMenuItems(currentSpeed float64) []Item {
	const eps = 0.0001
	items := make([]Item, len(SpeedOptions))

	for i, opt := range SpeedOptions {
		isCurrent := false
		if strings.HasSuffix(opt, "x") {
			if v, err := strconv.ParseFloat(strings.TrimSuffix(opt, "x"), 64); err == nil {
				if math.Abs(v-currentSpeed) < eps {
					isCurrent = true
				}
			}
		}

		title := opt
		if isCurrent {
			title = "✓ " + opt
		}

		items[i] = Item{Title: title, Value: ""}
	}

	// Add back option
	items = append(items, Item{Title: "Back", Value: ""})
	return items
}

// BuildIntervalMenuItems creates the interval selection menu items
func BuildIntervalMenuItems(currentInterval string) []Item {
	items := make([]Item, len(IntervalOptions))

	for i, opt := range IntervalOptions {
		title := opt
		if opt == currentInterval {
			title = "✓ " + opt
		}
		items[i] = Item{Title: title, Value: ""}
	}

	// Add back option
	items = append(items, Item{Title: "Back", Value: ""})
	return items
}

// BuildSystemMenuItems creates the system settings menu items
func BuildSystemMenuItems() []Item {
	return []Item{
		{Title: "Restart and check for updates", Value: "Restart the flow-frame service"},
		{Title: "Back", Value: ""},
	}
}

// ParseSpeedFromLabel extracts the speed value from a label string
func ParseSpeedFromLabel(label string) (float64, error) {
	cleanLabel := strings.TrimPrefix(label, "✓ ")
	if !strings.HasSuffix(cleanLabel, "x") {
		return 0, fmt.Errorf("invalid speed label format")
	}

	return strconv.ParseFloat(strings.TrimSuffix(cleanLabel, "x"), 64)
}

// CleanIntervalLabel removes the checkmark from an interval label
func CleanIntervalLabel(label string) string {
	return strings.TrimPrefix(label, "✓ ")
}
