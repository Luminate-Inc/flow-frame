package tabs

import (
	"flow-frame/ui"

	"github.com/veandco/go-sdl2/sdl"
	"github.com/veandco/go-sdl2/ttf"
)

// Widget manages tab navigation UI
type Widget struct {
	activeTab   TabID
	selectedTab TabID
	tabNames    []string
}

// NewWidget creates a new tab navigation widget
func NewWidget() *Widget {
	return &Widget{
		activeTab:   CollectionsTab,
		selectedTab: CollectionsTab,
		tabNames:    []string{"Collections", "Settings", "Close"},
	}
}

// ActiveTab returns the currently active tab
func (w *Widget) ActiveTab() TabID {
	return w.activeTab
}

// SetActiveTab sets the active tab
func (w *Widget) SetActiveTab(tab TabID) {
	if tab >= 0 && tab <= CloseTab {
		w.activeTab = tab
		w.selectedTab = tab
	}
}

// SelectedTab returns the currently selected tab
func (w *Widget) SelectedTab() TabID {
	return w.selectedTab
}

// Switch switches between tabs (handles wrapping)
func (w *Widget) Switch(direction int) {
	newTab := int(w.activeTab) + direction
	if newTab < 0 {
		newTab = int(CloseTab)
	} else if newTab > int(CloseTab) {
		newTab = int(CollectionsTab)
	}

	w.SetActiveTab(TabID(newTab))
}

// Draw renders the tab navigation
func (w *Widget) Draw(renderer *sdl.Renderer, x, y, width int32, font *ttf.Font) error {
	tabWidth := width / 3
	tabHeight := int32(60)

	for i, tabText := range w.tabNames {
		tabX := x + int32(i)*tabWidth
		tabID := TabID(i)

		isSelected := (tabID == w.selectedTab)
		isActive := (tabID == w.activeTab)

		// Draw tab background
		if isSelected {
			renderer.SetDrawColor(59, 130, 246, 255) // Blue background
		} else if isActive {
			renderer.SetDrawColor(51, 65, 85, 255)
		} else {
			renderer.SetDrawColor(30, 41, 59, 255)
		}
		renderer.FillRect(&sdl.Rect{X: tabX, Y: y, W: tabWidth, H: tabHeight})

		// Draw active tab indicator
		if isActive {
			renderer.SetDrawColor(59, 130, 246, 255)
			renderer.FillRect(&sdl.Rect{X: tabX + 20, Y: y + tabHeight - 4, W: tabWidth - 40, H: 4})
		}

		// Draw tab text
		if font != nil {
			color := sdl.Color{R: 148, G: 163, B: 184, A: 255}
			if isSelected || isActive {
				color = sdl.Color{R: 255, G: 255, B: 255, A: 255}
			}

			if err := ui.RenderText(renderer, tabText, tabX+20, y+18, color, font); err != nil {
				continue
			}
		}
	}

	return nil
}
