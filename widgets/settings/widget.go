package settings

import (
	"flow-frame/ui"

	"github.com/veandco/go-sdl2/sdl"
	"github.com/veandco/go-sdl2/ttf"
)

// Widget manages settings display and navigation
type Widget struct {
	items            []Item
	selected         int
	currentMenu      MenuType
	passwordInput    string
	passwordNetwork  string
	gridRow          int
	gridCol          int
	connectionStatus string
	statusMessage    string
}

// NewWidget creates a new settings widget
func NewWidget() *Widget {
	return &Widget{
		items:       []Item{},
		selected:    0,
		currentMenu: MainMenu,
	}
}

// SetItems updates the settings items
func (w *Widget) SetItems(items []Item) {
	w.items = items
	if w.selected >= len(items) {
		w.selected = 0
	}
}

// Items returns the current items
func (w *Widget) Items() []Item {
	return w.items
}

// Selected returns the selected item index
func (w *Widget) Selected() int {
	return w.selected
}

// SelectedItem returns the selected item
func (w *Widget) SelectedItem() Item {
	if w.selected >= 0 && w.selected < len(w.items) {
		return w.items[w.selected]
	}
	return Item{}
}

// CurrentMenu returns the current menu type
func (w *Widget) CurrentMenu() MenuType {
	return w.currentMenu
}

// SetCurrentMenu sets the current menu type
func (w *Widget) SetCurrentMenu(menu MenuType) {
	w.currentMenu = menu
	w.selected = 0
	w.statusMessage = "" // Clear status when changing menus
}

// SetStatusMessage sets a status message to display
func (w *Widget) SetStatusMessage(message string) {
	w.statusMessage = message
}

// ClearStatusMessage clears the status message
func (w *Widget) ClearStatusMessage() {
	w.statusMessage = ""
}

// MoveSelection moves selection up or down with wrapping
func (w *Widget) MoveSelection(delta int) {
	if len(w.items) == 0 {
		return
	}

	w.selected += delta
	if w.selected < 0 {
		w.selected = len(w.items) - 1
	} else if w.selected >= len(w.items) {
		w.selected = 0
	}
}

// Draw renders the settings tab
func (w *Widget) Draw(renderer *sdl.Renderer, x, y, width, height int32, largeFont, mediumFont, smallFont *ttf.Font) error {
	// Title
	if largeFont != nil {
		titleColor := sdl.Color{R: 255, G: 255, B: 255, A: 255}
		ui.RenderText(renderer, "Settings", x+40, y+20, titleColor, largeFont)
	}

	// Status message (if present)
	if w.statusMessage != "" && smallFont != nil {
		statusColor := sdl.Color{R: 34, G: 197, B: 94, A: 255} // Green
		ui.RenderText(renderer, w.statusMessage, x+40, y+60, statusColor, smallFont)
	}

	// Draw settings items
	itemHeight := int32(60)
	itemsStartY := y + 80
	if w.statusMessage != "" {
		itemsStartY = y + 100 // Push down if status message is shown
	}
	for i, item := range w.items {
		itemY := itemsStartY + int32(i)*itemHeight

		// Skip if item would be below visible area
		if itemY+itemHeight > y+height {
			break
		}

		// Highlight selected item
		if i == w.selected {
			renderer.SetDrawColor(51, 65, 85, 255)
			renderer.FillRect(&sdl.Rect{X: x + 20, Y: itemY, W: width - 40, H: itemHeight})
		}

		// Draw setting text
		if mediumFont != nil {
			color := sdl.Color{R: 255, G: 255, B: 255, A: 255}
			ui.RenderText(renderer, item.Title, x+40, itemY+10, color, mediumFont)

			if smallFont != nil && item.Value != "" {
				valueColor := sdl.Color{R: 148, G: 163, B: 184, A: 255}
				ui.RenderText(renderer, item.Value, x+40, itemY+35, valueColor, smallFont)
			}
		}
	}

	return nil
}

// DrawCloseTab renders the close tab content
func DrawCloseTab(renderer *sdl.Renderer, x, y, width, height int32, mediumFont *ttf.Font) error {
	// Title
	if mediumFont != nil {
		titleColor := sdl.Color{R: 255, G: 255, B: 255, A: 255}
		ui.RenderText(renderer, "Close", x+40, y+20, titleColor, mediumFont)
	}

	// Draw close selection item
	itemHeight := int32(60)
	itemY := y + 80

	// Highlight the close item
	renderer.SetDrawColor(51, 65, 85, 255)
	renderer.FillRect(&sdl.Rect{X: x + 20, Y: itemY, W: width - 40, H: itemHeight})

	// Draw close text
	if mediumFont != nil {
		color := sdl.Color{R: 255, G: 255, B: 255, A: 255}
		ui.RenderText(renderer, "Press confirm to close", x+40, itemY+20, color, mediumFont)
	}

	return nil
}

// keyboardGrid defines the visual keyboard layout
var keyboardGrid = [][]string{
	{"1", "2", "3", "4", "5", "6", "7", "8", "9", "0"},
	{"q", "w", "e", "r", "t", "y", "u", "i", "o", "p"},
	{"a", "s", "d", "f", "g", "h", "j", "k", "l", "-"},
	{"z", "x", "c", "v", "b", "n", "m", "_", ".", "@"},
	{"Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"},
	{"A", "S", "D", "F", "G", "H", "J", "K", "L", "!"},
	{"Z", "X", "C", "V", "B", "N", "M", "#", "$", "%"},
	{"&", "*", "(", ")", "/", "\\", ":", ";", "=", "+"},
	{"[", "]", "{", "}", "<", ">", "?", "|", "'", "\""},
	{"<SPACE>", "<BACKSPACE>", "<SUBMIT>", "<CANCEL>"},
}

// StartPasswordInput initializes the password input state
func (w *Widget) StartPasswordInput(networkSSID string) {
	w.passwordInput = ""
	w.passwordNetwork = networkSSID
	w.gridRow = 0
	w.gridCol = 0
	w.connectionStatus = ""
}

// GetPasswordInput returns the current password input
func (w *Widget) GetPasswordInput() string {
	return w.passwordInput
}

// GetPasswordNetwork returns the network SSID being configured
func (w *Widget) GetPasswordNetwork() string {
	return w.passwordNetwork
}

// SetConnectionStatus sets the connection status message
func (w *Widget) SetConnectionStatus(status string) {
	w.connectionStatus = status
}

// MoveGridRow moves the grid row position
func (w *Widget) MoveGridRow(delta int) {
	w.gridRow += delta
	if w.gridRow < 0 {
		w.gridRow = len(keyboardGrid) - 1
	} else if w.gridRow >= len(keyboardGrid) {
		w.gridRow = 0
	}
	// Adjust column if current row is shorter
	if w.gridCol >= len(keyboardGrid[w.gridRow]) {
		w.gridCol = len(keyboardGrid[w.gridRow]) - 1
	}
}

// MoveGridCol moves the grid column position
func (w *Widget) MoveGridCol(delta int) {
	w.gridCol += delta
	if w.gridCol < 0 {
		w.gridCol = len(keyboardGrid[w.gridRow]) - 1
	} else if w.gridCol >= len(keyboardGrid[w.gridRow]) {
		w.gridCol = 0
	}
}

// GetCurrentChar returns the currently selected character
func (w *Widget) GetCurrentChar() string {
	if w.gridRow >= 0 && w.gridRow < len(keyboardGrid) {
		if w.gridCol >= 0 && w.gridCol < len(keyboardGrid[w.gridRow]) {
			return keyboardGrid[w.gridRow][w.gridCol]
		}
	}
	return ""
}

// AddCharToPassword adds the selected character to the password
func (w *Widget) AddCharToPassword() {
	char := w.GetCurrentChar()
	if char == "<SPACE>" {
		w.passwordInput += " "
	} else if char != "<BACKSPACE>" && char != "<SUBMIT>" && char != "<CANCEL>" {
		w.passwordInput += char
	}
}

// Backspace removes the last character from the password
func (w *Widget) Backspace() {
	if len(w.passwordInput) > 0 {
		w.passwordInput = w.passwordInput[:len(w.passwordInput)-1]
	}
}

// DrawPasswordInput renders the password input screen with keyboard grid
func (w *Widget) DrawPasswordInput(renderer *sdl.Renderer, x, y, width, height int32, largeFont, mediumFont, smallFont *ttf.Font) error {
	// Title
	if largeFont != nil {
		titleColor := sdl.Color{R: 255, G: 255, B: 255, A: 255}
		ui.RenderText(renderer, "Enter WiFi Password", x+40, y+20, titleColor, largeFont)
	}

	// Network name
	if smallFont != nil {
		networkColor := sdl.Color{R: 148, G: 163, B: 184, A: 255}
		ui.RenderText(renderer, "Network: "+w.passwordNetwork, x+40, y+60, networkColor, smallFont)
	}

	// Current password (masked)
	if mediumFont != nil {
		passwordColor := sdl.Color{R: 255, G: 255, B: 255, A: 255}
		maskedPassword := ""
		for i := 0; i < len(w.passwordInput); i++ {
			maskedPassword += "*"
		}
		if maskedPassword == "" {
			maskedPassword = "(empty)"
		}
		ui.RenderText(renderer, "Password: "+maskedPassword, x+40, y+90, passwordColor, mediumFont)
	}

	// Connection status
	if w.connectionStatus != "" && smallFont != nil {
		statusColor := sdl.Color{R: 34, G: 197, B: 94, A: 255}
		if len(w.connectionStatus) > 5 && w.connectionStatus[:5] == "Error" {
			statusColor = sdl.Color{R: 239, G: 68, B: 68, A: 255}
		}
		ui.RenderText(renderer, w.connectionStatus, x+40, y+125, statusColor, smallFont)
	}

	// Keyboard grid
	gridStartY := y + 160
	keyWidth := int32(70)
	keyHeight := int32(45)
	keySpacing := int32(8)
	rowSpacing := int32(8)

	for rowIdx, row := range keyboardGrid {
		rowY := gridStartY + int32(rowIdx)*(keyHeight+rowSpacing)

		// Calculate starting X to center the row
		rowWidth := int32(len(row))*keyWidth + int32(len(row)-1)*keySpacing
		rowStartX := x + (width-rowWidth)/2

		for colIdx, key := range row {
			keyX := rowStartX + int32(colIdx)*(keyWidth+keySpacing)

			// Determine if this key is selected
			isSelected := (rowIdx == w.gridRow && colIdx == w.gridCol)

			// Draw key background
			if isSelected {
				renderer.SetDrawColor(59, 130, 246, 255) // Blue for selected
			} else {
				renderer.SetDrawColor(51, 65, 85, 255) // Gray for normal
			}

			// Special keys get wider width
			actualKeyWidth := keyWidth
			if key == "<SPACE>" || key == "<BACKSPACE>" || key == "<SUBMIT>" || key == "<CANCEL>" {
				actualKeyWidth = keyWidth * 2
			}

			renderer.FillRect(&sdl.Rect{X: keyX, Y: rowY, W: actualKeyWidth, H: keyHeight})

			// Draw key border
			renderer.SetDrawColor(30, 41, 59, 255)
			renderer.DrawRect(&sdl.Rect{X: keyX, Y: rowY, W: actualKeyWidth, H: keyHeight})

			// Draw key text
			if smallFont != nil {
				keyColor := sdl.Color{R: 255, G: 255, B: 255, A: 255}
				displayText := key
				if key == "<SPACE>" {
					displayText = "Space"
				} else if key == "<BACKSPACE>" {
					displayText = "Back"
				} else if key == "<SUBMIT>" {
					displayText = "Submit"
				} else if key == "<CANCEL>" {
					displayText = "Cancel"
				}

				// Center text in key
				textX := keyX + (actualKeyWidth / 2) - int32(len(displayText)*3)
				textY := rowY + (keyHeight / 2) - 8
				ui.RenderText(renderer, displayText, textX, textY, keyColor, smallFont)
			}
		}
	}

	// Instructions
	if smallFont != nil {
		instructColor := sdl.Color{R: 148, G: 163, B: 184, A: 255}
		instructY := gridStartY + int32(len(keyboardGrid))*(keyHeight+rowSpacing) + 10
		ui.RenderText(renderer, "Arrows: Navigate | Enter/Space: Select", x+40, instructY, instructColor, smallFont)
	}

	return nil
}
