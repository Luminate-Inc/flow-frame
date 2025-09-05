package root

import (
	"flow-frame/pkg/settings"
	"flow-frame/screens/videoPlayer"

	"github.com/veandco/go-sdl2/sdl"
)

// KeyPressTracker manages key press state to prevent duplicate key presses
type KeyPressTracker struct {
	pressed map[sdl.Scancode]bool
}

// NewKeyPressTracker creates a new KeyPressTracker
func NewKeyPressTracker() KeyPressTracker {
	return KeyPressTracker{
		pressed: make(map[sdl.Scancode]bool),
	}
}

// IsPressed checks if a key was just pressed (not held)
func (kpt *KeyPressTracker) IsPressed(keyState []uint8, scancode sdl.Scancode) bool {
	isCurrentlyPressed := keyState[scancode] != 0
	wasPressed := kpt.pressed[scancode]

	// Update state
	kpt.pressed[scancode] = isCurrentlyPressed

	// Return true only if key is currently pressed but wasn't pressed before
	return isCurrentlyPressed && !wasPressed
}

// MousePressTracker manages mouse button press state to prevent duplicate presses
type MousePressTracker struct {
	// Keyed by SDL button mask (e.g. sdl.ButtonLMask())
	pressed map[uint32]bool
}

// NewMousePressTracker creates a new MousePressTracker
func NewMousePressTracker() MousePressTracker {
	return MousePressTracker{
		pressed: make(map[uint32]bool),
	}
}

// IsPressed checks if a mouse button (by mask) was just pressed (not held)
func (mpt *MousePressTracker) IsPressed(mouseState uint32, buttonMask uint32) bool {
	isCurrentlyPressed := (mouseState & buttonMask) != 0
	wasPressed := mpt.pressed[buttonMask]

	// Update state
	mpt.pressed[buttonMask] = isCurrentlyPressed

	// Return true only if button is currently pressed but wasn't pressed before
	return isCurrentlyPressed && !wasPressed
}

// RootGame manages the main application state and video player
type RootGame struct {
	video *videoPlayer.VideoPlayerGame

	// SDL2 rendering
	window   *sdl.Window
	renderer *sdl.Renderer

	// UI state
	ui           *ModernUI
	popupVisible bool
	currentMenu  string
	menuItems    []string

	// Persisted user preferences
	settings settings.Settings

	// Input tracking
	keyState []uint8
	// Mouse button state bitmask from sdl.GetMouseState
	mouseButtons uint32

	// Key press state tracking to avoid duplicate calls
	keyTracker KeyPressTracker
	// Mouse press state tracking to avoid duplicate calls
	mouseTracker MousePressTracker
}
