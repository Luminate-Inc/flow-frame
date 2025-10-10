package ui

import "github.com/veandco/go-sdl2/sdl"

// DrawGradientRect draws a vertical gradient rectangle
func DrawGradientRect(renderer *sdl.Renderer, x, y, width, height int32, startColor, endColor [3]uint8) {
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
