package settings

// Settings represents user-tunable configuration that should persist across
// application restarts. Add additional fields here as new settings are
// introduced.
type Settings struct {
	PlaybackSpeed    float64 `json:"playbackSpeed"`
	PlaybackInterval string  `json:"playbackInterval"`
}

// Item represents a settings menu item
type Item struct {
	Title string
	Value string
}

// MenuType represents the type of settings menu being displayed
type MenuType string

const (
	MainMenu     MenuType = "main"
	SpeedMenu    MenuType = "speed"
	IntervalMenu MenuType = "interval"
	SystemMenu   MenuType = "system"
)
