package root

import (
	"flow-frame/pkg/settings"
	"flow-frame/screens/videoPlayer"
	"fmt"
	"log"
	"math"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/veandco/go-sdl2/sdl"
)

// Speed and interval options for the settings menus
var (
	speedOptions    = []string{"0.2x", "0.5x", "0.8x", "1x", "2x", "3x"}
	intervalOptions = []string{"Every minute", "Every hour", "Every 12 hours", "Every day", "Every week"}
)

// NewRootGame creates and initializes the root game
func NewRootGame(window *sdl.Window, renderer *sdl.Renderer) *RootGame {
	// Load settings first
	settings := settings.Load()

	// Create the root game
	rg := &RootGame{
		video:        videoPlayer.NewVideoPlayerGame(),
		window:       window,
		renderer:     renderer,
		popupVisible: false,
		currentMenu:  "main",
		settings:     settings,
		keyTracker:   NewKeyPressTracker(),
		mouseTracker: NewMousePressTracker(),
	}

	// Initialize modern UI system
	ui, err := NewModernUI()
	if err != nil {
		log.Printf("Warning: Failed to initialize UI: %v", err)
		// Continue without UI - basic fallback rendering will be used
	}
	rg.ui = ui

	// Configure video player with SDL2 renderer
	if err := rg.video.SetRenderer(renderer); err != nil {
		log.Printf("Warning: Failed to set renderer for video player: %v", err)
	}

	// Apply loaded settings to video player
	rg.video.SetPlaybackSpeed(settings.PlaybackSpeed)
	rg.video.SetPlaybackInterval(settings.PlaybackInterval)

	return rg
}

// Update handles SDL2 input and updates game state
func (rg *RootGame) Update() error {
	// Get current keyboard state - this is more efficient than polling events for held keys
	rg.keyState = sdl.GetKeyboardState()
	// Get current mouse buttons state (bitmask); we ignore x,y here
	_, _, buttons := sdl.GetMouseState()
	rg.mouseButtons = buttons

	// Handle input based on current state
	if rg.popupVisible {
		rg.handleUIInput()
		// Don't pass keyState to video player when popup is visible
		return rg.video.Update(nil)
	} else {
		rg.handleMainInput()
		// Pass keyState to video player only when popup is not visible
		return rg.video.Update(rg.keyState)
	}
}

// handleUIInput processes input when modern UI is visible
func (rg *RootGame) handleUIInput() {
	if rg.ui == nil {
		return
	}

	// Up/Down arrow navigation - navigate items within current tab
	if rg.keyTracker.IsPressed(rg.keyState, sdl.SCANCODE_DOWN) {
		rg.ui.MoveSelection(1)
	}

	if rg.keyTracker.IsPressed(rg.keyState, sdl.SCANCODE_UP) {
		rg.ui.MoveSelection(-1)
	}

	// Left/Right arrow navigation - switch between tabs
	if rg.keyTracker.IsPressed(rg.keyState, sdl.SCANCODE_LEFT) {
		rg.ui.SwitchTab(-1)
	}

	if rg.keyTracker.IsPressed(rg.keyState, sdl.SCANCODE_RIGHT) {
		rg.ui.SwitchTab(1)
	}

	// Multiple activation methods for cross-platform support
	// Enter/Return key/space mouse button/R mouse button/L
	if rg.keyTracker.IsPressed(rg.keyState, sdl.SCANCODE_RETURN) ||
		rg.keyTracker.IsPressed(rg.keyState, sdl.SCANCODE_SPACE) ||
		rg.mouseTracker.IsPressed(rg.mouseButtons, sdl.ButtonRMask()) ||
		rg.mouseTracker.IsPressed(rg.mouseButtons, sdl.ButtonLMask()) {
		rg.activateSelection()
	}

	// Back/Cancel/Exit
	if rg.keyTracker.IsPressed(rg.keyState, sdl.SCANCODE_ESCAPE) {
		rg.hideUI()
	}
}

// handleMainInput processes input when no UI is visible
func (rg *RootGame) handleMainInput() {
	// Show UI when down key is pressed
	if rg.keyTracker.IsPressed(rg.keyState, sdl.SCANCODE_DOWN) {
		rg.showModernUI()
	}
}

// Draw renders the complete frame using SDL2
func (rg *RootGame) Draw() error {
	// Get screen dimensions
	w, h := rg.window.GetSize()

	// Clear screen with black background
	rg.renderer.SetDrawColor(0, 0, 0, 255)
	rg.renderer.Clear()

	// Draw video player (main content)
	if err := rg.video.Draw(rg.renderer, w, h); err != nil {
		return err
	}

	// Draw loading icon if prefetch is pending
	if rg.video.IsPrefetchPending() {
		if err := rg.drawLoadingIcon(rg.renderer, w, h); err != nil {
			return err
		}
	}

	// Draw UI overlay if visible
	if rg.ui != nil && rg.popupVisible {
		if err := rg.ui.Draw(rg.renderer, w, h); err != nil {
			return err
		}
	}

	// Present the complete frame
	rg.renderer.Present()
	return nil
}

// showModernUI displays the modern tabbed UI
func (rg *RootGame) showModernUI() {
	if rg.ui == nil {
		return
	}

	// Create collection cards from video player data
	videoCollections := rg.video.Collections()
	collections := make([]CollectionCard, len(videoCollections))

	// Map video collections to UI cards with colors
	for i, vc := range videoCollections {
		var colorStart, colorEnd [3]uint8

		// Assign colors based on collection title
		switch vc.Title {
		case "Impressionism":
			colorStart = [3]uint8{41, 98, 255} // Blue start
			colorEnd = [3]uint8{13, 71, 161}   // Blue end
		case "Abstract":
			colorStart = [3]uint8{156, 39, 176} // Purple start
			colorEnd = [3]uint8{74, 20, 140}    // Purple end
		default:
			// Default gradient for other collections
			colorStart = [3]uint8{99, 102, 241} // Indigo start
			colorEnd = [3]uint8{67, 56, 202}    // Indigo end
		}

		collections[i] = CollectionCard{
			Title:       vc.Title,
			Description: vc.Description,
			ColorStart:  colorStart,
			ColorEnd:    colorEnd,
		}
	}

	// Create settings items
	settings := []SettingItem{
		{
			Title: "Playback Speed",
			Value: rg.getSpeedDisplayValue(),
		},
		{
			Title: "Playback Interval",
			Value: rg.video.PlaybackInterval(),
		},
		{
			Title: "System Settings",
			Value: "Configure system options",
		},
	}

	// Show the modern UI with collections tab active
	rg.ui.ShowPopup(collections, settings)
	rg.ui.SetActiveTab(0)   // Start with Collections tab
	rg.ui.SetSelectedTab(0) // Start with Collections tab selected
	rg.popupVisible = true
}

// getSpeedDisplayValue returns the current speed as a display string
func (rg *RootGame) getSpeedDisplayValue() string {
	speed := rg.video.PlaybackSpeed()
	return fmt.Sprintf("%.1fx", speed)
}

// activateSelection handles selection activation in the UI
func (rg *RootGame) activateSelection() {
	if rg.ui == nil {
		return
	}

	// Check if close button is selected
	if rg.ui.IsCloseButtonSelected() {
		rg.hideUI()
		return
	}

	// Handle regular item selection based on current tab
	selectedIndex := rg.ui.GetSelectedIndex()
	if rg.ui.GetActiveTab() == 0 {
		// Collections tab - select collection
		collections := rg.video.Collections()
		if selectedIndex >= 0 && selectedIndex < len(collections) {
			rg.video.SetRequestedCollection(selectedIndex)
			rg.hideUI()
		}
	} else {
		// Settings tab - handle based on current menu
		selectedItem := rg.ui.GetSelectedItem()

		switch rg.currentMenu {
		case "main":
			switch selectedIndex {
			case 0: // Playback Speed
				rg.showSpeedSettings()
			case 1: // Playback Interval
				rg.showIntervalSettings()
			case 2: // System Settings
				rg.showSystemSettings()
			}
		case "speed":
			if selectedItem == "Back" {
				rg.showModernUI() // Return to main UI
			} else {
				rg.applyPlaybackSpeed(selectedItem)
				rg.showModernUI() // Return to main UI after applying
			}
		case "interval":
			if selectedItem == "Back" {
				rg.showModernUI() // Return to main UI
			} else {
				rg.applyPlaybackInterval(selectedItem)
				rg.showModernUI() // Return to main UI after applying
			}
		case "system":
			if selectedItem == "Back" {
				rg.showModernUI() // Return to main UI
			} else if selectedItem == "Restart and check for updates" {
				rg.restartSystem()
			}
		}
	}
}

// showSpeedSettings displays speed selection as a settings submenu
func (rg *RootGame) showSpeedSettings() {
	current := rg.video.PlaybackSpeed()
	const eps = 0.0001

	settingsItems := make([]SettingItem, len(speedOptions))
	for i, opt := range speedOptions {
		// Check if this is the current speed
		isCurrent := false
		if strings.HasSuffix(opt, "x") {
			if v, err := strconv.ParseFloat(strings.TrimSuffix(opt, "x"), 64); err == nil {
				if abs(v-current) < eps {
					isCurrent = true
				}
			}
		}

		title := opt
		if isCurrent {
			title = "✓ " + opt
		}

		settingsItems[i] = SettingItem{Title: title, Value: ""}
	}

	// Add back option
	settingsItems = append(settingsItems, SettingItem{Title: "Back", Value: ""})

	rg.ui.ShowPopup(nil, settingsItems)
	rg.ui.SetActiveTab(1) // Settings tab
	rg.currentMenu = "speed"
}

// showIntervalSettings displays interval selection as a settings submenu
func (rg *RootGame) showIntervalSettings() {
	current := rg.video.PlaybackInterval()

	settingsItems := make([]SettingItem, len(intervalOptions))
	for i, opt := range intervalOptions {
		title := opt
		if opt == current {
			title = "✓ " + opt
		}
		settingsItems[i] = SettingItem{Title: title, Value: ""}
	}

	// Add back option
	settingsItems = append(settingsItems, SettingItem{Title: "Back", Value: ""})

	rg.ui.ShowPopup(nil, settingsItems)
	rg.ui.SetActiveTab(1) // Settings tab
	rg.currentMenu = "interval"
}

// showSystemSettings displays system settings submenu
func (rg *RootGame) showSystemSettings() {
	settingsItems := []SettingItem{
		{Title: "Restart and check for updates", Value: "Restart the flow-frame service"},
		{Title: "Back", Value: ""},
	}

	rg.ui.ShowPopup(nil, settingsItems)
	rg.ui.SetActiveTab(1) // Settings tab
	rg.currentMenu = "system"
}

// restartSystem executes the systemctl restart command
func (rg *RootGame) restartSystem() {
	log.Println("Executing system restart command...")

	// Execute the systemctl restart command
	cmd := exec.Command("sudo", "systemctl", "restart", "flow-frame")

	// Run the command in the background since it will terminate this process
	go func() {
		if err := cmd.Run(); err != nil {
			log.Printf("Error executing restart command: %v", err)
		}
	}()

	// Hide the UI immediately since the application will restart
	rg.hideUI()
}

// hideUI hides the modern UI
func (rg *RootGame) hideUI() {
	if rg.ui != nil {
		rg.ui.HidePopup()
	}
	rg.popupVisible = false
	rg.currentMenu = "main"
}

// applyPlaybackSpeed updates video playback speed and saves setting
func (rg *RootGame) applyPlaybackSpeed(label string) {
	cleanLabel := strings.TrimPrefix(label, "✓ ")
	if strings.HasSuffix(cleanLabel, "x") {
		if v, err := strconv.ParseFloat(strings.TrimSuffix(cleanLabel, "x"), 64); err == nil {
			rg.video.SetPlaybackSpeed(v)
			rg.settings.PlaybackSpeed = v
			if err := settings.Save(rg.settings); err != nil {
				log.Printf("Warning: Failed to save playback speed setting: %v", err)
			}
		}
	}
}

// applyPlaybackInterval updates video playback interval and saves setting
func (rg *RootGame) applyPlaybackInterval(label string) {
	cleanLabel := strings.TrimPrefix(label, "✓ ")
	rg.video.SetPlaybackInterval(cleanLabel)
	rg.settings.PlaybackInterval = cleanLabel
	if err := settings.Save(rg.settings); err != nil {
		log.Printf("Warning: Failed to save playback interval setting: %v", err)
	}
}

// Close cleans up resources
func (rg *RootGame) Close() {
	if rg.ui != nil {
		rg.ui.Close()
	}
}

// drawLoadingIcon draws a simple loading spinner in the bottom right corner
func (rg *RootGame) drawLoadingIcon(renderer *sdl.Renderer, screenWidth, screenHeight int32) error {
	// Loading icon parameters
	iconSize := int32(24)
	margin := int32(20)
	centerX := screenWidth - margin - iconSize/2
	centerY := screenHeight - margin - iconSize/2

	// Use current time to create rotation effect
	angle := float64(time.Now().UnixMilli()/50) * 0.1 // Rotate based on time

	// Draw a simple spinning circle with segments
	renderer.SetDrawColor(255, 255, 255, 180) // White with some transparency

	// Draw 8 segments around the circle, with varying opacity to create spinner effect
	for i := 0; i < 8; i++ {
		segmentAngle := angle + float64(i)*math.Pi/4 // 45 degree increments

		// Calculate segment position
		radius := float64(iconSize / 2)
		x1 := centerX + int32(radius*0.6*math.Cos(segmentAngle))
		y1 := centerY + int32(radius*0.6*math.Sin(segmentAngle))
		x2 := centerX + int32(radius*math.Cos(segmentAngle))
		y2 := centerY + int32(radius*math.Sin(segmentAngle))

		// Fade segments based on position in rotation
		opacity := uint8(255 * (float64(i) + 1) / 8)
		renderer.SetDrawColor(255, 255, 255, opacity)

		// Draw thick line segment
		for thickness := int32(0); thickness < 3; thickness++ {
			renderer.DrawLine(x1+thickness, y1, x2+thickness, y2)
			renderer.DrawLine(x1, y1+thickness, x2, y2+thickness)
		}
	}

	return nil
}

// abs returns the absolute value of a float64
func abs(x float64) float64 {
	if x < 0 {
		return -x
	}
	return x
}
