package settings

import (
	"flow-frame/ui"

	"github.com/veandco/go-sdl2/sdl"
	"github.com/veandco/go-sdl2/ttf"
)

// Widget manages settings display and navigation
type Widget struct {
	items       []Item
	selected    int
	currentMenu MenuType
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

	// Draw settings items
	itemHeight := int32(60)
	for i, item := range w.items {
		itemY := y + 80 + int32(i)*itemHeight

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
