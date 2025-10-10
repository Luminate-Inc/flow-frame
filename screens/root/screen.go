package root

import (
	"flow-frame/pkg/input"
	"flow-frame/pkg/sharedTypes"
	"flow-frame/screens/videoPlayer"
	"flow-frame/ui"
	"flow-frame/widgets/collections"
	"flow-frame/widgets/settings"
	"flow-frame/widgets/tabs"
	"log"
	"os/exec"

	"github.com/veandco/go-sdl2/sdl"
)

// NewRootScreen creates and initializes the root screen
func NewRootScreen(window *sdl.Window, renderer *sdl.Renderer) *RootScreen {
	// Load settings first
	userSettings := settings.Load()

	// Create the root screen
	rg := &RootScreen{
		video:        videoPlayer.NewVideoPlayerScreen(),
		window:       window,
		renderer:     renderer,
		popupVisible: false,
		settings:     userSettings,
		keyTracker:   input.NewKeyPressTracker(),
		mouseTracker: input.NewMousePressTracker(),
	}

	// Initialize UI components
	fonts, err := ui.LoadFonts()
	if err != nil {
		log.Printf("Warning: Failed to initialize fonts: %v", err)
	}
	rg.fonts = fonts

	rg.tabsWidget = tabs.NewWidget()
	rg.collectionsWidget = collections.NewWidget()
	rg.settingsWidget = settings.NewWidget()

	// Configure video player with SDL2 renderer
	if err := rg.video.SetRenderer(renderer); err != nil {
		log.Printf("Warning: Failed to set renderer for video player: %v", err)
	}

	// Apply loaded settings to video player
	rg.video.SetPlaybackSpeed(userSettings.PlaybackSpeed)
	rg.video.SetPlaybackInterval(userSettings.PlaybackInterval)

	return rg
}

// Update handles SDL2 input and updates screen state
func (rg *RootScreen) Update() error {
	// Get current keyboard state
	rg.keyState = sdl.GetKeyboardState()
	// Get current mouse buttons state
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

// handleUIInput processes input when UI is visible
func (rg *RootScreen) handleUIInput() {
	// Up/Down arrow navigation - navigate items within current tab
	if rg.keyTracker.IsPressed(rg.keyState, sdl.SCANCODE_DOWN) {
		switch rg.tabsWidget.ActiveTab() {
		case tabs.CollectionsTab:
			rg.collectionsWidget.MoveSelection(1)
		case tabs.SettingsTab:
			rg.settingsWidget.MoveSelection(1)
		}
	}

	if rg.keyTracker.IsPressed(rg.keyState, sdl.SCANCODE_UP) {
		switch rg.tabsWidget.ActiveTab() {
		case tabs.CollectionsTab:
			rg.collectionsWidget.MoveSelection(-1)
		case tabs.SettingsTab:
			rg.settingsWidget.MoveSelection(-1)
		}
	}

	// Left/Right arrow navigation - switch between tabs
	if rg.keyTracker.IsPressed(rg.keyState, sdl.SCANCODE_LEFT) {
		rg.tabsWidget.Switch(-1)
	}

	if rg.keyTracker.IsPressed(rg.keyState, sdl.SCANCODE_RIGHT) {
		rg.tabsWidget.Switch(1)
	}

	// Multiple activation methods for cross-platform support
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
func (rg *RootScreen) handleMainInput() {
	// Show UI when down key is pressed
	if rg.keyTracker.IsPressed(rg.keyState, sdl.SCANCODE_DOWN) {
		rg.showUI()
	}
}

// Draw renders the complete frame using SDL2
func (rg *RootScreen) Draw() error {
	// Get screen dimensions
	w, h := rg.window.GetSize()

	// Clear screen with black background
	rg.renderer.SetDrawColor(0, 0, 0, 255)
	rg.renderer.Clear()

	// Draw video player (main content)
	if err := rg.video.Draw(rg.renderer, w, h); err != nil {
		return err
	}

	// Draw UI overlay if visible
	if rg.popupVisible {
		if err := rg.drawUI(w, h); err != nil {
			return err
		}
	}

	// Present the complete frame
	rg.renderer.Present()
	return nil
}

// drawUI renders the UI overlay
func (rg *RootScreen) drawUI(screenWidth, screenHeight int32) error {
	if rg.fonts == nil {
		return nil
	}

	// Draw dark background overlay
	rg.renderer.SetDrawBlendMode(sdl.BLENDMODE_BLEND)
	rg.renderer.SetDrawColor(15, 23, 42, 220)
	rg.renderer.FillRect(&sdl.Rect{X: 0, Y: 0, W: screenWidth, H: screenHeight})

	// Calculate UI dimensions
	uiWidth := int32(float64(screenWidth) * 0.8)
	uiHeight := int32(float64(screenHeight) * 0.8)
	uiX := (screenWidth - uiWidth) / 2
	uiY := (screenHeight - uiHeight) / 2

	// Draw main UI background
	rg.renderer.SetDrawColor(30, 41, 59, 255)
	rg.renderer.FillRect(&sdl.Rect{X: uiX, Y: uiY, W: uiWidth, H: uiHeight})

	// Draw tabs
	if err := rg.tabsWidget.Draw(rg.renderer, uiX, uiY, uiWidth, rg.fonts.Medium); err != nil {
		return err
	}

	// Draw content based on active tab
	contentY := uiY + 80
	contentHeight := uiHeight - 80

	switch rg.tabsWidget.ActiveTab() {
	case tabs.CollectionsTab:
		if err := rg.collectionsWidget.Draw(rg.renderer, uiX, contentY, uiWidth, contentHeight, rg.fonts.Large, rg.fonts.Small); err != nil {
			return err
		}
	case tabs.SettingsTab:
		if err := rg.settingsWidget.Draw(rg.renderer, uiX, contentY, uiWidth, contentHeight, rg.fonts.Large, rg.fonts.Medium, rg.fonts.Small); err != nil {
			return err
		}
	case tabs.CloseTab:
		if err := settings.DrawCloseTab(rg.renderer, uiX, contentY, uiWidth, contentHeight, rg.fonts.Medium); err != nil {
			return err
		}
	}

	// Draw navigation hints
	if err := rg.drawNavigationHints(uiX, uiY, uiWidth, uiHeight); err != nil {
		return err
	}

	return nil
}

// drawNavigationHints renders helpful navigation hints
func (rg *RootScreen) drawNavigationHints(uiX, uiY, uiWidth, uiHeight int32) error {
	if rg.fonts.Small == nil {
		return nil
	}

	hintColor := sdl.Color{R: 156, G: 163, B: 175, A: 255}
	hintY := uiY + uiHeight - 30

	ui.RenderText(rg.renderer, "Up/Down Navigate Items | Left/Right Switch Tabs | Enter Select | ESC Close", uiX+20, hintY, hintColor, rg.fonts.Small)

	return nil
}

// showUI displays the UI with all current data
func (rg *RootScreen) showUI() {
	// Create collection cards from video player data
	videoCollections := rg.video.Collections()
	cards := make([]collections.Card, len(videoCollections))

	for i, vc := range videoCollections {
		cards[i] = rg.mapCollectionToCard(vc)
	}

	rg.collectionsWidget.SetCards(cards)

	// Create settings items
	items := settings.BuildMainMenuItems(rg.video.PlaybackSpeed(), rg.video.PlaybackInterval())
	rg.settingsWidget.SetItems(items)
	rg.settingsWidget.SetCurrentMenu(settings.MainMenu)

	// Show UI with Collections tab active
	rg.tabsWidget.SetActiveTab(tabs.CollectionsTab)
	rg.popupVisible = true
}

// mapCollectionToCard converts a video collection to a UI card
func (rg *RootScreen) mapCollectionToCard(vc sharedTypes.Collection) collections.Card {
	var colorStart, colorEnd [3]uint8

	switch vc.Title {
	case "Impressionism":
		colorStart = [3]uint8{41, 98, 255}
		colorEnd = [3]uint8{13, 71, 161}
	case "Abstract":
		colorStart = [3]uint8{156, 39, 176}
		colorEnd = [3]uint8{74, 20, 140}
	default:
		colorStart = [3]uint8{99, 102, 241}
		colorEnd = [3]uint8{67, 56, 202}
	}

	return collections.Card{
		Title:       vc.Title,
		Description: vc.Description,
		ColorStart:  colorStart,
		ColorEnd:    colorEnd,
	}
}

// activateSelection handles selection activation in the UI
func (rg *RootScreen) activateSelection() {
	switch rg.tabsWidget.ActiveTab() {
	case tabs.CollectionsTab:
		rg.handleCollectionSelection()
	case tabs.SettingsTab:
		rg.handleSettingsSelection()
	case tabs.CloseTab:
		rg.hideUI()
	}
}

// handleCollectionSelection processes collection selection
func (rg *RootScreen) handleCollectionSelection() {
	selectedIndex := rg.collectionsWidget.Selected()
	videoCollections := rg.video.Collections()

	if selectedIndex >= 0 && selectedIndex < len(videoCollections) {
		rg.video.SetRequestedCollection(selectedIndex)
		rg.hideUI()
	}
}

// handleSettingsSelection processes settings selection
func (rg *RootScreen) handleSettingsSelection() {
	selectedItem := rg.settingsWidget.SelectedItem()

	switch rg.settingsWidget.CurrentMenu() {
	case settings.MainMenu:
		rg.handleMainMenuSelection(rg.settingsWidget.Selected())
	case settings.SpeedMenu:
		rg.handleSpeedMenuSelection(selectedItem.Title)
	case settings.IntervalMenu:
		rg.handleIntervalMenuSelection(selectedItem.Title)
	case settings.SystemMenu:
		rg.handleSystemMenuSelection(selectedItem.Title)
	}
}

// handleMainMenuSelection handles main settings menu selections
func (rg *RootScreen) handleMainMenuSelection(index int) {
	switch index {
	case 0: // Playback Speed
		items := settings.BuildSpeedMenuItems(rg.video.PlaybackSpeed())
		rg.settingsWidget.SetItems(items)
		rg.settingsWidget.SetCurrentMenu(settings.SpeedMenu)
	case 1: // Playback Interval
		items := settings.BuildIntervalMenuItems(rg.video.PlaybackInterval())
		rg.settingsWidget.SetItems(items)
		rg.settingsWidget.SetCurrentMenu(settings.IntervalMenu)
	case 2: // System Settings
		items := settings.BuildSystemMenuItems()
		rg.settingsWidget.SetItems(items)
		rg.settingsWidget.SetCurrentMenu(settings.SystemMenu)
	}
}

// handleSpeedMenuSelection handles speed menu selections
func (rg *RootScreen) handleSpeedMenuSelection(label string) {
	if label == "Back" {
		rg.showUI()
		return
	}

	if speed, err := settings.ParseSpeedFromLabel(label); err == nil {
		rg.video.SetPlaybackSpeed(speed)
		rg.settings.PlaybackSpeed = speed
		if err := settings.Save(rg.settings); err != nil {
			log.Printf("Warning: Failed to save playback speed setting: %v", err)
		}
	}

	rg.showUI()
}

// handleIntervalMenuSelection handles interval menu selections
func (rg *RootScreen) handleIntervalMenuSelection(label string) {
	if label == "Back" {
		rg.showUI()
		return
	}

	cleanLabel := settings.CleanIntervalLabel(label)
	rg.video.SetPlaybackInterval(cleanLabel)
	rg.settings.PlaybackInterval = cleanLabel
	if err := settings.Save(rg.settings); err != nil {
		log.Printf("Warning: Failed to save playback interval setting: %v", err)
	}

	rg.showUI()
}

// handleSystemMenuSelection handles system menu selections
func (rg *RootScreen) handleSystemMenuSelection(label string) {
	if label == "Back" {
		rg.showUI()
		return
	}

	if label == "Restart and check for updates" {
		rg.restartSystem()
	}
}

// restartSystem executes the systemctl restart command
func (rg *RootScreen) restartSystem() {
	log.Println("Executing system restart command...")

	cmd := exec.Command("sudo", "systemctl", "restart", "flow-frame")

	go func() {
		if err := cmd.Run(); err != nil {
			log.Printf("Error executing restart command: %v", err)
		}
	}()

	rg.hideUI()
}

// hideUI hides the UI
func (rg *RootScreen) hideUI() {
	rg.popupVisible = false
	rg.settingsWidget.SetCurrentMenu(settings.MainMenu)
}

// Close cleans up resources
func (rg *RootScreen) Close() {
	if rg.fonts != nil {
		rg.fonts.Close()
	}
}
