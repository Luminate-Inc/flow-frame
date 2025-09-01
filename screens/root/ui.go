package root

import (
	"fmt"

	"github.com/veandco/go-sdl2/sdl"
	"github.com/veandco/go-sdl2/ttf"
)

// ModernUI provides a modern tabbed interface with gradient cards
type ModernUI struct {
	fonts struct {
		large  *ttf.Font // 32px for card titles
		medium *ttf.Font // 24px for tab titles
		small  *ttf.Font // 18px for descriptions
	}
	visible         bool
	activeTab       int // 0 = Collections, 1 = Settings, 2 = Close
	collections     []CollectionCard
	settings        []SettingItem
	selectedCard    int
	selectedSetting int
	selectedTab     int  // New field for tab selection
	showCloseButton  bool // New field to control close button visibility
}

// CollectionCard represents a collection with visual styling
type CollectionCard struct {
	Title       string
	Description string
	ColorStart  [3]uint8 // RGB start color for gradient
	ColorEnd    [3]uint8 // RGB end color for gradient
}

// SettingItem represents a settings menu item
type SettingItem struct {
	Title string
	Value string
}

// NewModernUI creates a new modern UI system
func NewModernUI() (*ModernUI, error) {
	// Initialize TTF
	if err := ttf.Init(); err != nil {
		return nil, fmt.Errorf("failed to initialize TTF: %v", err)
	}

	ui := &ModernUI{
		visible:         false,
		activeTab:       0,
		selectedCard:    0,
		selectedSetting: 0,
		selectedTab:     0,
		showCloseButton:  false,
	}

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
		ui.fonts.large, err = ttf.OpenFont(path, 32)
		if err == nil {
			break
		}
	}

	for _, path := range fontPaths {
		// Medium font for tab titles
		ui.fonts.medium, err = ttf.OpenFont(path, 24)
		if err == nil {
			break
		}
	}

	for _, path := range fontPaths {
		// Small font for descriptions
		ui.fonts.small, err = ttf.OpenFont(path, 18)
		if err == nil {
			break
		}
	}

	// Define collection cards with matching colors from the image
	ui.collections = []CollectionCard{
		{
			Title:       "Impressionism",
			Description: "Light, color, and fleeting moments.",
			ColorStart:  [3]uint8{41, 98, 255}, // Blue start
			ColorEnd:    [3]uint8{13, 71, 161}, // Blue end
		},
		{
			Title:       "Abstract",
			Description: "Beyond the tangible world.",
			ColorStart:  [3]uint8{156, 39, 176}, // Purple start
			ColorEnd:    [3]uint8{74, 20, 140},  // Purple end
		},
	}

	return ui, nil
}

// ShowPopup displays the modern UI with tabs
func (ui *ModernUI) ShowPopup(collections []CollectionCard, settings []SettingItem) {
	if len(collections) > 0 {
		ui.collections = collections
	}
	ui.settings = settings
	ui.visible = true
	ui.selectedCard = 0
	ui.selectedSetting = 0
	ui.selectedTab = 0       // Start with Collections tab selected
	ui.showCloseButton = true // Enable close button
}

// HidePopup hides the UI
func (ui *ModernUI) HidePopup() {
	ui.visible = false
}

// IsVisible returns whether the UI is currently visible
func (ui *ModernUI) IsVisible() bool {
	return ui.visible
}

// SetActiveTab switches between tabs (0=Collections, 1=Settings, 2=Close)
func (ui *ModernUI) SetActiveTab(tab int) {
	if tab >= 0 && tab <= 2 {
		ui.activeTab = tab
	}
}

// GetActiveTab returns the current active tab
func (ui *ModernUI) GetActiveTab() int {
	return ui.activeTab
}

// SetSelectedTab sets the currently selected tab
func (ui *ModernUI) SetSelectedTab(tab int) {
	if tab >= 0 && tab <= 2 {
		ui.selectedTab = tab
	}
}

// MoveSelection moves selection within the active tab (up/down navigation)
func (ui *ModernUI) MoveSelection(delta int) {
	if ui.activeTab == 0 { // Collections tab
		maxIndex := len(ui.collections)
		if maxIndex > 0 {
			ui.selectedCard += delta
			if ui.selectedCard < 0 {
				ui.selectedCard = maxIndex - 1 // Wrap to last item
			} else if ui.selectedCard >= maxIndex {
				ui.selectedCard = 0 // Wrap to first item
			}
		}
	} else if ui.activeTab == 1 { // Settings tab
		maxIndex := len(ui.settings)
		if maxIndex > 0 {
			ui.selectedSetting += delta
			if ui.selectedSetting < 0 {
				ui.selectedSetting = maxIndex - 1 // Wrap to last item
			} else if ui.selectedSetting >= maxIndex {
				ui.selectedSetting = 0 // Wrap to first item
			}
		}
	} else if ui.activeTab == 2 { // Close tab
		// Close tab has only one item (the close button), so no movement needed
		// Selection is always on the close button
	}
}

// SwitchTab switches between tabs (left/right navigation)
func (ui *ModernUI) SwitchTab(direction int) {
	newTab := ui.activeTab + direction
	if newTab < 0 {
		newTab = 2 // Wrap to Close tab
	} else if newTab > 2 {
		newTab = 0 // Wrap to Collections tab
	}

	ui.SetActiveTab(newTab)
	ui.selectedTab = newTab // Keep selectedTab in sync

	// Reset selection to first item when switching tabs
	if newTab == 0 {
		ui.selectedCard = 0
	} else if newTab == 1 {
		ui.selectedSetting = 0
	}
	// No reset needed for Close tab (only one item)
}

// GetSelectedIndex returns the selected item index for the active tab
func (ui *ModernUI) GetSelectedIndex() int {
	if ui.activeTab == 0 {
		return ui.selectedCard
	} else if ui.activeTab == 1 {
		return ui.selectedSetting
	} else if ui.activeTab == 2 {
		return 0 // Close tab has only one item (close button)
	}
	return 0
}

// GetSelectedTab returns the currently selected tab
func (ui *ModernUI) GetSelectedTab() int {
	return ui.selectedTab
}

// IsCloseButtonSelected returns true if the close button is currently selected
func (ui *ModernUI) IsCloseButtonSelected() bool {
	// Close button is selected when we're in the Close tab
	return ui.activeTab == 2
}

// Draw renders the modern UI
func (ui *ModernUI) Draw(renderer *sdl.Renderer, screenWidth, screenHeight int32) error {
	if !ui.visible {
		return nil
	}

	// Draw dark background overlay
	renderer.SetDrawBlendMode(sdl.BLENDMODE_BLEND)
	renderer.SetDrawColor(15, 23, 42, 220) // Dark blue-gray with transparency
	renderer.FillRect(&sdl.Rect{X: 0, Y: 0, W: screenWidth, H: screenHeight})

	// Calculate UI dimensions
	uiWidth := int32(float64(screenWidth) * 0.8)
	uiHeight := int32(float64(screenHeight) * 0.8)
	uiX := (screenWidth - uiWidth) / 2
	uiY := (screenHeight - uiHeight) / 2

	// Draw main UI background
	renderer.SetDrawColor(30, 41, 59, 255) // Dark background
	renderer.FillRect(&sdl.Rect{X: uiX, Y: uiY, W: uiWidth, H: uiHeight})

	// Draw tabs
	if err := ui.drawTabs(renderer, uiX, uiY, uiWidth); err != nil {
		return err
	}

	// Draw content based on active tab
	contentY := uiY + 80 // Space for tabs
	contentHeight := uiHeight - 80

	if ui.activeTab == 0 {
		if err := ui.drawCollectionsTab(renderer, uiX, contentY, uiWidth, contentHeight); err != nil {
			return err
		}
	} else if ui.activeTab == 1 {
		if err := ui.drawSettingsTab(renderer, uiX, contentY, uiWidth, contentHeight); err != nil {
			return err
		}
	} else if ui.activeTab == 2 {
		if err := ui.drawCloseTab(renderer, uiX, contentY, uiWidth, contentHeight); err != nil {
			return err
		}
	}

	// Close button is now part of the tab content, not drawn separately

	// Draw navigation hints
	if err := ui.drawNavigationHints(renderer, uiX, uiY, uiWidth, uiHeight); err != nil {
		return err
	}

	return nil
}

// drawTabs renders the tab navigation
func (ui *ModernUI) drawTabs(renderer *sdl.Renderer, x, y, width int32) error {
	tabWidth := width / 3
	tabHeight := int32(60)

	tabs := []string{"Collections", "Settings", "Close"}

	for i, tabText := range tabs {
		tabX := x + int32(i)*tabWidth

		// Determine if this tab is selected or active
		isSelected := (i == ui.selectedTab)
		isActive := (i == ui.activeTab)

		// Draw tab background
		if isSelected {
			// Selected tab - highlighted background
			renderer.SetDrawColor(59, 130, 246, 255) // Blue background
		} else if isActive {
			// Active tab - lighter background
			renderer.SetDrawColor(51, 65, 85, 255)
		} else {
			// Inactive tab - darker background
			renderer.SetDrawColor(30, 41, 59, 255)
		}
		renderer.FillRect(&sdl.Rect{X: tabX, Y: y, W: tabWidth, H: tabHeight})

		// Draw active tab indicator (blue line at bottom) for active tab
		if isActive {
			renderer.SetDrawColor(59, 130, 246, 255) // Blue accent
			renderer.FillRect(&sdl.Rect{X: tabX + 20, Y: y + tabHeight - 4, W: tabWidth - 40, H: 4})
		}

		// Draw tab text
		if ui.fonts.medium != nil {
			color := sdl.Color{R: 148, G: 163, B: 184, A: 255} // Gray
			if isSelected || isActive {
				color = sdl.Color{R: 255, G: 255, B: 255, A: 255} // White for selected/active
			}

			if err := ui.renderText(renderer, tabText, tabX+20, y+18, color, ui.fonts.medium); err != nil {
				continue // Skip on error but don't fail
			}
		}
	}

	return nil
}

// drawCollectionsTab renders the collections cards
func (ui *ModernUI) drawCollectionsTab(renderer *sdl.Renderer, x, y, width, height int32) error {
	if len(ui.collections) == 0 {
		return nil
	}

	// Title
	if ui.fonts.large != nil {
		titleColor := sdl.Color{R: 255, G: 255, B: 255, A: 255}
		if err := ui.renderText(renderer, "Collections", x+40, y+20, titleColor, ui.fonts.large); err == nil {
			// Description
			if ui.fonts.small != nil {
				descColor := sdl.Color{R: 148, G: 163, B: 184, A: 255}
				ui.renderText(renderer, "Select a collection to begin flowing the show", x+40, y+60, descColor, ui.fonts.small)
			}
		}
	}

	// Draw collection cards
	cardStartY := y + 120
	cardSpacing := int32(20)
	cardHeight := int32(200)
	cardsPerRow := int32(2)
	cardWidth := (width - 80 - cardSpacing) / cardsPerRow

	for i, collection := range ui.collections {
		row := int32(i) / cardsPerRow
		col := int32(i) % cardsPerRow

		cardX := x + 40 + col*(cardWidth+cardSpacing)
		cardY := cardStartY + row*(cardHeight+cardSpacing)

		// Skip if card would be below visible area
		if cardY+cardHeight > y+height {
			break
		}

		if err := ui.drawCollectionCard(renderer, collection, cardX, cardY, cardWidth, cardHeight, i == ui.selectedCard); err != nil {
			continue // Skip failed cards
		}
	}

	return nil
}

// drawCollectionCard renders a single collection card with gradient
func (ui *ModernUI) drawCollectionCard(renderer *sdl.Renderer, card CollectionCard, x, y, width, height int32, selected bool) error {
	// Draw gradient background
	ui.drawGradientRect(renderer, x, y, width, height, card.ColorStart, card.ColorEnd)

	// Draw selection border if selected
	if selected {
		renderer.SetDrawColor(255, 255, 255, 255)
		for i := 0; i < 3; i++ {
			renderer.DrawRect(&sdl.Rect{X: x - int32(i), Y: y - int32(i), W: width + int32(i*2), H: height + int32(i*2)})
		}
	}

	// Draw card title
	if ui.fonts.large != nil {
		titleColor := sdl.Color{R: 255, G: 255, B: 255, A: 255}
		ui.renderText(renderer, card.Title, x+30, y+30, titleColor, ui.fonts.large)
	}

	// Draw card description
	if ui.fonts.small != nil {
		descColor := sdl.Color{R: 255, G: 255, B: 255, A: 200} // Slightly transparent
		ui.renderText(renderer, card.Description, x+30, y+height-60, descColor, ui.fonts.small)
	}

	return nil
}

// drawGradientRect draws a vertical gradient rectangle
func (ui *ModernUI) drawGradientRect(renderer *sdl.Renderer, x, y, width, height int32, startColor, endColor [3]uint8) {
	// Draw gradient by drawing horizontal lines with interpolated colors
	for i := int32(0); i < height; i++ {
		t := float64(i) / float64(height-1)

		r := uint8(float64(startColor[0])*(1-t) + float64(endColor[0])*t)
		g := uint8(float64(startColor[1])*(1-t) + float64(endColor[1])*t)
		b := uint8(float64(startColor[2])*(1-t) + float64(endColor[2])*t)

		renderer.SetDrawColor(r, g, b, 255)
		renderer.DrawLine(x, y+i, x+width-1, y+i)
	}
}

// drawSettingsTab renders the settings panel
func (ui *ModernUI) drawSettingsTab(renderer *sdl.Renderer, x, y, width, height int32) error {
	// Title
	if ui.fonts.large != nil {
		titleColor := sdl.Color{R: 255, G: 255, B: 255, A: 255}
		ui.renderText(renderer, "Settings", x+40, y+20, titleColor, ui.fonts.large)
	}

	// Draw settings items
	itemHeight := int32(60)
	for i, setting := range ui.settings {
		itemY := y + 80 + int32(i)*itemHeight

		// Skip if item would be below visible area
		if itemY+itemHeight > y+height {
			break
		}

		// Highlight selected item
		if i == ui.selectedSetting {
			renderer.SetDrawColor(51, 65, 85, 255)
			renderer.FillRect(&sdl.Rect{X: x + 20, Y: itemY, W: width - 40, H: itemHeight})
		}

		// Draw setting text
		if ui.fonts.medium != nil {
			color := sdl.Color{R: 255, G: 255, B: 255, A: 255}
			ui.renderText(renderer, setting.Title, x+40, itemY+10, color, ui.fonts.medium)

			if ui.fonts.small != nil && setting.Value != "" {
				valueColor := sdl.Color{R: 148, G: 163, B: 184, A: 255}
				ui.renderText(renderer, setting.Value, x+40, itemY+35, valueColor, ui.fonts.small)
			}
		}
	}

	return nil
}

// drawCloseTab renders the close tab with a settings-style selection
func (ui *ModernUI) drawCloseTab(renderer *sdl.Renderer, x, y, width, height int32) error {
	// Title
	if ui.fonts.large != nil {
		titleColor := sdl.Color{R: 255, G: 255, B: 255, A: 255}
		ui.renderText(renderer, "Close", x+40, y+20, titleColor, ui.fonts.large)
	}

	// Draw close selection item (like settings items)
	itemHeight := int32(60)
	itemY := y + 80

	// Highlight the close item (always selected)
	renderer.SetDrawColor(51, 65, 85, 255) // Same as settings selection
	renderer.FillRect(&sdl.Rect{X: x + 20, Y: itemY, W: width - 40, H: itemHeight})

	// Draw close text
	if ui.fonts.medium != nil {
		color := sdl.Color{R: 255, G: 255, B: 255, A: 255}
		ui.renderText(renderer, "Press confirm to close", x+40, itemY+20, color, ui.fonts.medium)
	}

	return nil
}

// drawNavigationHints renders helpful navigation hints at the bottom of the UI
func (ui *ModernUI) drawNavigationHints(renderer *sdl.Renderer, uiX, uiY, uiWidth, uiHeight int32) error {
	if ui.fonts.small == nil {
		return nil
	}

	hintColor := sdl.Color{R: 156, G: 163, B: 175, A: 255} // Gray-400
	hintY := uiY + uiHeight - 30

	// Navigation hints
	ui.renderText(renderer, "Up/Down Navigate Items | Left/Right Switch Tabs | Enter Select | ESC Close", uiX+20, hintY, hintColor, ui.fonts.small)

	return nil
}

// renderText renders text at the specified position
func (ui *ModernUI) renderText(renderer *sdl.Renderer, text string, x, y int32, color sdl.Color, font *ttf.Font) error {
	if font == nil {
		return fmt.Errorf("font not available")
	}

	surface, err := font.RenderUTF8Blended(text, color)
	if err != nil {
		return err
	}
	defer surface.Free()

	texture, err := renderer.CreateTextureFromSurface(surface)
	if err != nil {
		return err
	}
	defer texture.Destroy()

	_, _, w, h, err := texture.Query()
	if err != nil {
		return err
	}

	dstRect := sdl.Rect{X: x, Y: y, W: w, H: h}
	return renderer.Copy(texture, nil, &dstRect)
}

// Close cleans up UI resources
func (ui *ModernUI) Close() {
	if ui.fonts.large != nil {
		ui.fonts.large.Close()
	}
	if ui.fonts.medium != nil {
		ui.fonts.medium.Close()
	}
	if ui.fonts.small != nil {
		ui.fonts.small.Close()
	}
	ttf.Quit()
}

// Backward compatibility - keeping SimpleUI as an alias for transition
type SimpleUI = ModernUI

// Legacy methods for backward compatibility
func NewSimpleUI() (*SimpleUI, error) {
	return NewModernUI()
}

// ShowPopupLegacy converts legacy popup calls to modern UI
func (ui *ModernUI) ShowPopupLegacy(title string, items []string) {
	// Convert legacy popup to modern settings tab
	settings := make([]SettingItem, len(items))
	for i, item := range items {
		settings[i] = SettingItem{Title: item, Value: ""}
	}

	ui.ShowPopup(nil, settings)
	ui.SetActiveTab(1) // Show settings tab for legacy popups
}

func (ui *ModernUI) GetSelected() int {
	return ui.GetSelectedIndex()
}

func (ui *ModernUI) GetSelectedItem() string {
	if ui.activeTab == 0 && ui.selectedCard < len(ui.collections) {
		return ui.collections[ui.selectedCard].Title
	}
	if ui.activeTab == 1 && ui.selectedSetting < len(ui.settings) {
		return ui.settings[ui.selectedSetting].Title
	}
	return ""
}
