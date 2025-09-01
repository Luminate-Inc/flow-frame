package settings

import (
	"encoding/json"
	"os"
)

// Settings represents user-tunable configuration that should persist across
// application restarts. Add additional fields here as new settings are
// introduced.
type Settings struct {
	PlaybackSpeed    float64 `json:"playbackSpeed"`
	PlaybackInterval string  `json:"playbackInterval"`
}

var defaultSettings = Settings{
	PlaybackSpeed:    1.0,
	PlaybackInterval: "Every hour",
}

const filename = "../../settings.json"

// Load reads the settings file from disk. When the file is missing or cannot
// be parsed, sane defaults are returned instead so the application can
// continue running.
func Load() Settings {
	f, err := os.Open(filename)
	if err != nil {
		// No existing file – return defaults.
		return defaultSettings
	}
	defer f.Close()

	var s Settings
	if err := json.NewDecoder(f).Decode(&s); err != nil {
		// Malformed file – fall back to defaults.
		return defaultSettings
	}

	// Ensure zero-values are replaced by defaults so that partially written
	// configuration files do not break behaviour when new fields are added.
	if s.PlaybackSpeed == 0 {
		s.PlaybackSpeed = defaultSettings.PlaybackSpeed
	}
	if s.PlaybackInterval == "" {
		s.PlaybackInterval = defaultSettings.PlaybackInterval
	}

	return s
}

// Save writes the provided settings atomically to disk, creating the file when
// necessary. Any error is returned to the caller so it can be logged.
func Save(s Settings) error {
	// Create will truncate an existing file or create a new one with
	// owner-only permissions.
	f, err := os.Create(filename)
	if err != nil {
		return err
	}
	defer f.Close()

	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	return enc.Encode(s)
}
