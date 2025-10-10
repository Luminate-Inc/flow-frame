package collections

import (
	"flow-frame/ui"

	"github.com/veandco/go-sdl2/sdl"
	"github.com/veandco/go-sdl2/ttf"
)

// DrawCard renders a single collection card with gradient
func DrawCard(renderer *sdl.Renderer, card Card, x, y, width, height int32, selected bool, largeFont, smallFont *ttf.Font) error {
	// Draw gradient background
	ui.DrawGradientRect(renderer, x, y, width, height, card.ColorStart, card.ColorEnd)

	// Draw selection border if selected
	if selected {
		renderer.SetDrawColor(255, 255, 255, 255)
		for i := 0; i < 3; i++ {
			renderer.DrawRect(&sdl.Rect{X: x - int32(i), Y: y - int32(i), W: width + int32(i*2), H: height + int32(i*2)})
		}
	}

	// Draw card title
	if largeFont != nil {
		titleColor := sdl.Color{R: 255, G: 255, B: 255, A: 255}
		ui.RenderText(renderer, card.Title, x+30, y+30, titleColor, largeFont)
	}

	// Draw card description
	if smallFont != nil {
		descColor := sdl.Color{R: 255, G: 255, B: 255, A: 200}
		ui.RenderText(renderer, card.Description, x+30, y+height-60, descColor, smallFont)
	}

	return nil
}
