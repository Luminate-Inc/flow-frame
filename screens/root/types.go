package root

import (
	"context"
	"flow-frame/pkg/captiveportal"
	"flow-frame/pkg/input"
	"flow-frame/widgets/settings"
	"flow-frame/screens/videoPlayer"
	"flow-frame/ui"
	"flow-frame/widgets/collections"
	captiveportalwidget "flow-frame/widgets/captiveportal"
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

	// Captive portal for WiFi setup
	captivePortal       *captiveportal.Portal
	captivePortalWidget *captiveportalwidget.Widget
	showCaptivePortal   bool
	wifiMonitorCtx      context.Context
	wifiMonitorCancel   context.CancelFunc

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
