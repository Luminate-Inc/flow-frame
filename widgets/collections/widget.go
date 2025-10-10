package collections

import (
	"flow-frame/ui"

	"github.com/veandco/go-sdl2/sdl"
	"github.com/veandco/go-sdl2/ttf"
)

// Widget manages collection cards display and selection
type Widget struct {
	cards    []Card
	selected int
}

// NewWidget creates a new collections widget
func NewWidget() *Widget {
	return &Widget{
		cards:    []Card{},
		selected: 0,
	}
}

// SetCards updates the collection cards
func (w *Widget) SetCards(cards []Card) {
	w.cards = cards
	if w.selected >= len(cards) {
		w.selected = 0
	}
}

// Cards returns the current cards
func (w *Widget) Cards() []Card {
	return w.cards
}

// Selected returns the selected card index
func (w *Widget) Selected() int {
	return w.selected
}

// MoveSelection moves selection up or down with wrapping
func (w *Widget) MoveSelection(delta int) {
	if len(w.cards) == 0 {
		return
	}

	w.selected += delta
	if w.selected < 0 {
		w.selected = len(w.cards) - 1
	} else if w.selected >= len(w.cards) {
		w.selected = 0
	}
}

// Draw renders the collections tab
func (w *Widget) Draw(renderer *sdl.Renderer, x, y, width, height int32, largeFont, smallFont *ttf.Font) error {
	// Title
	if largeFont != nil {
		titleColor := sdl.Color{R: 255, G: 255, B: 255, A: 255}
		if err := ui.RenderText(renderer, "Collections", x+40, y+20, titleColor, largeFont); err == nil {
			// Description
			if smallFont != nil {
				descColor := sdl.Color{R: 148, G: 163, B: 184, A: 255}
				ui.RenderText(renderer, "Select a collection to begin flowing the show", x+40, y+60, descColor, smallFont)
			}
		}
	}

	// Draw collection cards
	cardStartY := y + 120
	cardSpacing := int32(20)
	cardHeight := int32(200)
	cardsPerRow := int32(2)
	cardWidth := (width - 80 - cardSpacing) / cardsPerRow

	for i, card := range w.cards {
		row := int32(i) / cardsPerRow
		col := int32(i) % cardsPerRow

		cardX := x + 40 + col*(cardWidth+cardSpacing)
		cardY := cardStartY + row*(cardHeight+cardSpacing)

		// Skip if card would be below visible area
		if cardY+cardHeight > y+height {
			break
		}

		if err := DrawCard(renderer, card, cardX, cardY, cardWidth, cardHeight, i == w.selected, largeFont, smallFont); err != nil {
			continue
		}
	}

	return nil
}
