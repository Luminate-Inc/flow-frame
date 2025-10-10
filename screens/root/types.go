package root

import (
	"flow-frame/pkg/input"
	"flow-frame/widgets/settings"
	"flow-frame/screens/videoPlayer"
	"flow-frame/ui"
	"flow-frame/widgets/collections"
	"flow-frame/widgets/tabs"

	"github.com/veandco/go-sdl2/sdl"
)

// RootGame manages the main application state and video player
type RootScreen struct {
	video *videoPlayer.VideoPlayerScreen

	// SDL2 rendering
	window   *sdl.Window
	renderer *sdl.Renderer

	// UI components
	fonts             *ui.Fonts
	tabsWidget        *tabs.Widget
	collectionsWidget *collections.Widget
	settingsWidget    *settings.Widget
	popupVisible      bool

	// Persisted user preferences
	settings settings.Settings

	// Input tracking
	keyState []uint8
	// Mouse button state bitmask from sdl.GetMouseState
	mouseButtons uint32

	// Key press state tracking to avoid duplicate calls
	keyTracker input.KeyPressTracker
	// Mouse press state tracking to avoid duplicate calls
	mouseTracker input.MousePressTracker
}
