package captiveportal

import (
	"bytes"
	"fmt"
	"image/png"

	"github.com/veandco/go-sdl2/sdl"

	"flow-frame/ui"
)

// Widget displays the captive portal QR code overlay
type Widget struct {
	qrTexture  *sdl.Texture
	portalSSID string
	portalURL  string
	qrWidth    int32
	qrHeight   int32
}

// NewWidget creates a new captive portal widget
func NewWidget(renderer *sdl.Renderer, qrPNG []byte, ssid, url string) (*Widget, error) {
	// Decode PNG image
	img, err := png.Decode(bytes.NewReader(qrPNG))
	if err != nil {
		return nil, fmt.Errorf("failed to decode QR code PNG: %w", err)
	}

	// Get image dimensions
	bounds := img.Bounds()
	width := bounds.Dx()
	height := bounds.Dy()

	// Create SDL surface
	surface, err := sdl.CreateRGBSurface(0, int32(width), int32(height), 32,
		0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000)
	if err != nil {
		return nil, fmt.Errorf("failed to create SDL surface: %w", err)
	}
	defer surface.Free()

	// Copy image data to surface
	surface.Lock()
	pixels := surface.Pixels()
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			r, g, b, a := img.At(x, y).RGBA()
			// Convert from 16-bit to 8-bit
			offset := (y*width + x) * 4
			pixels[offset] = byte(r >> 8)
			pixels[offset+1] = byte(g >> 8)
			pixels[offset+2] = byte(b >> 8)
			pixels[offset+3] = byte(a >> 8)
		}
	}
	surface.Unlock()

	// Create texture from surface
	texture, err := renderer.CreateTextureFromSurface(surface)
	if err != nil {
		return nil, fmt.Errorf("failed to create texture from surface: %w", err)
	}

	return &Widget{
		qrTexture:  texture,
		portalSSID: ssid,
		portalURL:  url,
		qrWidth:    int32(width),
		qrHeight:   int32(height),
	}, nil
}

// Render draws the captive portal overlay modal
func (w *Widget) Render(renderer *sdl.Renderer, windowWidth, windowHeight int32, fonts *ui.Fonts) error {
	// Calculate modal dimensions (1/3 of screen height, centered)
	modalWidth := int32(400)
	modalHeight := windowHeight / 3

	// Ensure minimum height
	if modalHeight < 300 {
		modalHeight = 300
	}

	// Center the modal
	modalX := (windowWidth - modalWidth) / 2
	modalY := (windowHeight - modalHeight) / 2

	// Draw semi-transparent dark overlay over entire screen
	renderer.SetDrawBlendMode(sdl.BLENDMODE_BLEND)
	renderer.SetDrawColor(0, 0, 0, 220) // Dark with 220 opacity (matching existing pattern)
	renderer.FillRect(&sdl.Rect{X: 0, Y: 0, W: windowWidth, H: windowHeight})

	// Draw modal background
	bgColor := sdl.Color{R: 30, G: 41, B: 59, A: 255} // Dark slate background
	renderer.SetDrawColor(bgColor.R, bgColor.G, bgColor.B, bgColor.A)
	renderer.FillRect(&sdl.Rect{X: modalX, Y: modalY, W: modalWidth, H: modalHeight})

	// Draw modal border
	borderColor := sdl.Color{R: 59, G: 130, B: 246, A: 255} // Blue border
	renderer.SetDrawColor(borderColor.R, borderColor.G, borderColor.B, borderColor.A)
	renderer.DrawRect(&sdl.Rect{X: modalX, Y: modalY, W: modalWidth, H: modalHeight})

	// Text colors
	whiteColor := sdl.Color{R: 255, G: 255, B: 255, A: 255}
	grayColor := sdl.Color{R: 148, G: 163, B: 184, A: 255}

	// Current Y position for laying out elements
	currentY := modalY + 20

	// Render title
	titleText := "No WiFi Connection"
	if err := ui.RenderText(renderer, titleText, modalX+20, currentY, whiteColor, fonts.Large); err != nil {
		return fmt.Errorf("failed to render title: %w", err)
	}
	currentY += 40

	// Render instructions
	instructionText := "Scan QR code to connect device to WiFi"
	if err := ui.RenderText(renderer, instructionText, modalX+20, currentY, grayColor, fonts.Small); err != nil {
		return fmt.Errorf("failed to render instructions: %w", err)
	}
	currentY += 30

	// Render QR code (centered horizontally)
	qrX := modalX + (modalWidth-w.qrWidth)/2
	qrRect := sdl.Rect{X: qrX, Y: currentY, W: w.qrWidth, H: w.qrHeight}
	if err := renderer.Copy(w.qrTexture, nil, &qrRect); err != nil {
		return fmt.Errorf("failed to render QR code: %w", err)
	}
	currentY += w.qrHeight + 20

	// Render SSID
	ssidText := fmt.Sprintf("Network: %s", w.portalSSID)
	if err := ui.RenderText(renderer, ssidText, modalX+20, currentY, whiteColor, fonts.Medium); err != nil {
		return fmt.Errorf("failed to render SSID: %w", err)
	}
	currentY += 30

	// Render URL
	if err := ui.RenderText(renderer, w.portalURL, modalX+20, currentY, grayColor, fonts.Small); err != nil {
		return fmt.Errorf("failed to render URL: %w", err)
	}

	return nil
}

// Destroy cleans up widget resources
func (w *Widget) Destroy() {
	if w.qrTexture != nil {
		w.qrTexture.Destroy()
		w.qrTexture = nil
	}
}
