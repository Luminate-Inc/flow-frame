package ui

import (
	"fmt"

	"github.com/veandco/go-sdl2/sdl"
	"github.com/veandco/go-sdl2/ttf"
)

// RenderText renders text at the specified position with the given font and color
func RenderText(renderer *sdl.Renderer, text string, x, y int32, color sdl.Color, font *ttf.Font) error {
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
