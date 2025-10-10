package ui

import (
	"fmt"

	"github.com/veandco/go-sdl2/ttf"
)

// Fonts manages a set of TrueType fonts at different sizes
type Fonts struct {
	Large  *ttf.Font // 32px for card titles
	Medium *ttf.Font // 24px for tab titles
	Small  *ttf.Font // 18px for descriptions
}

// LoadFonts loads system fonts with fallbacks for different platforms
func LoadFonts() (*Fonts, error) {
	// Initialize TTF
	if err := ttf.Init(); err != nil {
		return nil, fmt.Errorf("failed to initialize TTF: %v", err)
	}

	fonts := &Fonts{}

	// Try to load system fonts with fallbacks
	fontPaths := []string{
		"/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
		"/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
		"/System/Library/Fonts/Helvetica.ttc",
		"/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
	}

	var err error
	for _, path := range fontPaths {
		// Large font for card titles
		fonts.Large, err = ttf.OpenFont(path, 32)
		if err == nil {
			break
		}
	}

	for _, path := range fontPaths {
		// Medium font for tab titles
		fonts.Medium, err = ttf.OpenFont(path, 24)
		if err == nil {
			break
		}
	}

	for _, path := range fontPaths {
		// Small font for descriptions
		fonts.Small, err = ttf.OpenFont(path, 18)
		if err == nil {
			break
		}
	}

	return fonts, nil
}

// Close cleans up font resources
func (f *Fonts) Close() {
	if f.Large != nil {
		f.Large.Close()
	}
	if f.Medium != nil {
		f.Medium.Close()
	}
	if f.Small != nil {
		f.Small.Close()
	}
}
