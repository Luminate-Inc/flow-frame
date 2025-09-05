package main

import (
	"fmt"
	"log"
	"os"
	"runtime"
	"runtime/debug"
	"time"
	"unsafe"

	"github.com/joho/godotenv"
	"github.com/veandco/go-sdl2/sdl"

	"flow-frame/screens/root"
)

const (
	targetFPS      = 60
	fallbackWidth  = 1920
	fallbackHeight = 1080
)

func main() {
	// CRITICAL: Lock OS thread immediately before any other operations
	runtime.LockOSThread()

	// Configure ARM64-specific memory management and CGO environment
	setupARMMemoryManagement()

	// Configure logging
	log.SetFlags(log.LstdFlags | log.Lshortfile)

	// Load environment configuration
	if err := godotenv.Load(); err != nil {
		log.Printf("Warning: .env file not found: %v", err)
	}

	// Get window title
	windowTitle := os.Getenv("GAME_TITLE")
	if windowTitle == "" {
		windowTitle = "Art Frame"
	}

	// Initialize SDL2 with fallback options
	if err := initializeSDL2(); err != nil {
		log.Fatalf("Failed to initialize SDL2: %v", err)
	}
	defer func() {
		log.Println("Shutting down SDL2...")
		sdl.Quit()
		runtime.GC()
	}()

	// Get display dimensions
	screenWidth, screenHeight := getDisplayDimensions()
	log.Printf("Starting %s | Resolution: %dx%d", windowTitle, screenWidth, screenHeight)

	// Debug display information
	logDisplayInfo()

	// Create SDL2 window
	window, err := createWindow(windowTitle, screenWidth, screenHeight)
	if err != nil {
		log.Fatalf("Failed to create window: %v", err)
	}
	defer window.Destroy()

	// Create SDL2 renderer with optimal settings
	renderer, err := createRenderer(window)
	if err != nil {
		log.Fatalf("Failed to create renderer: %v", err)
	}
	defer renderer.Destroy()

	// Create and initialize the game
	game := root.NewRootGame(window, renderer)
	defer game.Close()

	// Run the main game loop
	runGameLoop(game)

	log.Println("Art Frame shutting down...")
}

// setupARMMemoryManagement configures ARM64-specific memory settings and CGO environment
func setupARMMemoryManagement() {
	log.Printf("Configuring ARM64 memory management...")

	// Set ARM64 specific environment variables early
	os.Setenv("GODEBUG", "madvdontneed=1") // Removed gctrace=1 to stop GC log spam
	os.Setenv("GOMAXPROCS", "1")
	os.Setenv("GOGC", "25")
	os.Setenv("GOMEMLIMIT", "256MiB")

	// Set CGO environment variables for safer memory management
	os.Setenv("CGO_CFLAGS", "-O1 -g -fPIC")
	os.Setenv("CGO_LDFLAGS", "-Wl,--no-as-needed -fPIC")

	// Force minimal memory usage pattern with reasonable limits
	debug.SetGCPercent(25)          // Aggressive but not too aggressive GC
	debug.SetMemoryLimit(256 << 20) // 256MB limit - reasonable for Pi 5

	// Multiple GC cycles to establish stable memory pattern
	for i := 0; i < 3; i++ {
		runtime.GC()
		time.Sleep(100 * time.Millisecond)
	}

	log.Printf("ARM64 memory management configured: GOGC=25, GOMEMLIMIT=256MiB, GOMAXPROCS=1")
}

// initializeSDL2 initializes SDL2 with fallback video drivers
func initializeSDL2() error {
	// Force a GC cycle before SDL2 initialization to prevent interference
	runtime.GC()
	runtime.GC() // Double GC to ensure clean state

	// Small delay to ensure system is ready
	time.Sleep(100 * time.Millisecond)

	// Respect environment variable first, then fallback
	envDriver := os.Getenv("SDL_VIDEODRIVER")
	var videoDrivers []string

	if envDriver != "" {
		log.Printf("Using environment SDL_VIDEODRIVER: %s", envDriver)
		// Use environment driver first, then fallbacks including fbcon for Pi
		videoDrivers = []string{envDriver, "fbcon", "software", "dummy"}
	} else {
		// Platform-specific video driver fallbacks
		if runtime.GOOS == "darwin" {
			// macOS-specific drivers
			videoDrivers = []string{
				"cocoa",    // Native macOS driver
				"software", // Software rendering fallback
				"dummy",    // Last resort for testing
			}
		} else {
			// Linux/Raspberry Pi drivers
			videoDrivers = []string{
				"kmsdrm",   // Kernel Mode Setting + DRM - best for Pi 4/5 GPU
				"drm",      // Direct Rendering Manager fallback
				"fbcon",    // Direct framebuffer console - good for headless Pi
				"wayland",  // Wayland (requires compositor)
				"x11",      // X11 fallback
				"software", // Software rendering (needs display server)
				"dummy",    // Last resort for testing
			}
		}
	}

	currentDriver := os.Getenv("SDL_VIDEODRIVER")
	if currentDriver != "" {
		log.Printf("Current SDL_VIDEODRIVER: %s", currentDriver)
	}

	// Log system information for debugging
	log.Printf("=== System Information ===")
	log.Printf("OS: %s", runtime.GOOS)
	log.Printf("DISPLAY: %s", os.Getenv("DISPLAY"))

	// Check for Raspberry Pi specific information
	if _, err := os.Stat("/proc/device-tree/model"); err == nil {
		if model, err := os.ReadFile("/proc/device-tree/model"); err == nil {
			log.Printf("Device: %s", string(model))
		}
	}

	// Check framebuffer availability
	if _, err := os.Stat("/dev/fb0"); err == nil {
		log.Printf("Framebuffer /dev/fb0: available")
	} else {
		log.Printf("Framebuffer /dev/fb0: not available (%v)", err)
	}

	// Check DRI/KMS availability
	if _, err := os.Stat("/dev/dri"); err == nil {
		log.Printf("DRI directory: available")
	} else {
		log.Printf("DRI directory: not available")
	}

	log.Printf("=== End System Information ===")

	// Try each fallback driver
	for _, driver := range videoDrivers {
		log.Printf("Attempting SDL2 initialization with %s driver", driver)

		// Set the video driver
		os.Setenv("SDL_VIDEODRIVER", driver)

		// Try to initialize SDL2 with this driver
		if err := trySDLInitialization(driver); err != nil {
			log.Printf("SDL2 initialization failed with %s driver: %v", driver, err)
			continue
		}

		log.Printf("SDL2 successfully initialized with %s driver", driver)
		return nil
	}

	return fmt.Errorf("all SDL2 video drivers failed")
}

// trySDLInitialization attempts to initialize SDL2 with safer error handling
func trySDLInitialization(driver string) error {
	// Clean up any previous SDL2 state
	sdl.Quit()
	runtime.GC()
	time.Sleep(100 * time.Millisecond)

	// Set driver-specific hints for better compatibility
	switch driver {
	case "cocoa":
		sdl.SetHint(sdl.HINT_VIDEODRIVER, "cocoa")
		// macOS-specific hints for better compatibility
		sdl.SetHint("SDL_VIDEO_COCOA_ALLOW_SCREENSAVER", "1")
		sdl.SetHint("SDL_VIDEO_COCOA_SCALE_FACTOR", "1")
		sdl.SetHint("SDL_RENDER_DRIVER", "opengl") // Use OpenGL for hardware acceleration
	case "kmsdrm":
		// Specific hints for KMS/DRM on Raspberry Pi
		sdl.SetHint(sdl.HINT_VIDEODRIVER, "kmsdrm")
		sdl.SetHint("SDL_KMSDRM_REQUIRE_DRM_MASTER", "1")
		sdl.SetHint("SDL_VIDEO_KMSDRM_DEVINDEX", "0")
		// Prevent async flips that cause VC4 errors
		sdl.SetHint("SDL_RENDER_VSYNC", "1")
		sdl.SetHint("SDL_VIDEO_ALLOW_SCREENSAVER", "0")
		// Force synchronous operations
		sdl.SetHint("SDL_HINT_RENDER_BATCHING", "0")
	case "fbcon":
		// Framebuffer console driver
		sdl.SetHint(sdl.HINT_VIDEODRIVER, "fbcon")
		sdl.SetHint("SDL_FBDEV", "/dev/fb0")
	case "drm":
		sdl.SetHint(sdl.HINT_VIDEODRIVER, "drm")
		// Basic DRM hints
		sdl.SetHint("SDL_VIDEODRIVER", "drm")
	case "wayland":
		sdl.SetHint(sdl.HINT_VIDEODRIVER, "wayland")
		// Set basic Wayland-specific hints
		sdl.SetHint("SDL_VIDEO_WAYLAND_WMCLASS", "flow-frame")
	case "x11":
		sdl.SetHint(sdl.HINT_VIDEODRIVER, "x11")
		sdl.SetHint("SDL_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR", "0")
	case "software":
		sdl.SetHint(sdl.HINT_VIDEODRIVER, "software")
		sdl.SetHint("SDL_FRAMEBUFFER_ACCELERATION", "0")
	case "dummy":
		sdl.SetHint(sdl.HINT_VIDEODRIVER, "dummy")
	}

	// Set common hints for better performance and stability
	sdl.SetHint(sdl.HINT_RENDER_BATCHING, "1")
	// Allow hardware acceleration for GPU drivers, fallback to software for others
	if driver == "kmsdrm" || driver == "drm" {
		sdl.SetHint(sdl.HINT_RENDER_DRIVER, "opengles2") // Use OpenGL ES 2.0 for hardware acceleration
	} else if driver == "cocoa" {
		sdl.SetHint(sdl.HINT_RENDER_DRIVER, "opengl") // Use OpenGL for macOS hardware acceleration
	} else {
		sdl.SetHint(sdl.HINT_RENDER_DRIVER, "software") // Use software renderer for fbcon and other non-GPU drivers
	}
	sdl.SetHint(sdl.HINT_VIDEO_MINIMIZE_ON_FOCUS_LOSS, "0")

	// Initialize SDL2 directly on main thread (required for macOS Cocoa)
	// Try to initialize video subsystem only first
	if err := sdl.Init(sdl.INIT_VIDEO); err != nil {
		return fmt.Errorf("SDL_INIT_VIDEO failed: %v", err)
	}

	// Check if we can get video driver info
	driverName, err := sdl.GetCurrentVideoDriver()
	if err != nil {
		return fmt.Errorf("failed to get video driver: %v", err)
	}
	log.Printf("Video driver initialized: %s", driverName)

	// Try to add audio subsystem separately (non-fatal if it fails)
	if err := sdl.InitSubSystem(sdl.INIT_AUDIO); err != nil {
		log.Printf("Warning: Audio initialization failed: %v", err)
		// Continue without audio - this is not critical
	} else {
		log.Printf("Audio subsystem initialized successfully")
	}

	return nil
}

// getDisplayDimensions returns the screen dimensions or fallback values
func getDisplayDimensions() (int32, int32) {
	// Already locked to main thread, no need to lock again
	displayMode, err := sdl.GetCurrentDisplayMode(0)
	if err != nil {
		log.Printf("Warning: Failed to get display mode, using fallback: %v", err)
		return fallbackWidth, fallbackHeight
	}

	// Force garbage collection after CGO call
	runtime.GC()

	// Use full display dimensions for all platforms
	return displayMode.W, displayMode.H
}

// logDisplayInfo outputs debugging information about the display setup
func logDisplayInfo() {
	log.Printf("=== Display Configuration Debug ===")

	// Get current video driver
	if driver, err := sdl.GetCurrentVideoDriver(); err == nil {
		log.Printf("SDL2 Video Driver: %s", driver)
	} else {
		log.Printf("SDL2 Video Driver: unknown (%v)", err)
	}

	// Get number of displays
	numDisplays, err := sdl.GetNumVideoDisplays()
	if err != nil {
		log.Printf("Failed to get number of displays: %v", err)
		return
	}
	log.Printf("Number of displays: %d", numDisplays)

	// Get display information for each display
	for i := 0; i < numDisplays; i++ {
		if mode, err := sdl.GetCurrentDisplayMode(i); err == nil {
			log.Printf("Display %d: %dx%d @ %dHz", i, mode.W, mode.H, mode.RefreshRate)
		} else {
			log.Printf("Display %d: failed to get mode (%v)", i, err)
		}

		if name, err := sdl.GetDisplayName(i); err == nil {
			log.Printf("Display %d name: %s", i, name)
		}
	}

	log.Printf("=== End Display Configuration ===")
}

// createWindow creates an SDL2 window with optimal settings
func createWindow(title string, width, height int32) (*sdl.Window, error) {
	// Already locked to main thread, no need to lock again

	// Platform-specific window creation
	var windowFlags uint32 = sdl.WINDOW_SHOWN
	var x, y int32 = 0, 0

	if runtime.GOOS == "darwin" {
		// macOS: Use fullscreen mode
		windowFlags |= sdl.WINDOW_FULLSCREEN
		x = 0
		y = 0
	} else {
		// Linux/Pi: Use fullscreen for direct GPU access
		windowFlags |= sdl.WINDOW_FULLSCREEN
		x = 0
		y = 0
	}

	window, err := sdl.CreateWindow(
		title,
		x,
		y,
		width,
		height,
		windowFlags,
	)

	if err != nil {
		return nil, err
	}

	// Ensure window pointer is kept alive
	_ = unsafe.Pointer(window)
	runtime.GC()

	return window, nil
}

// createRenderer creates an SDL2 renderer with hardware acceleration and VSync
func createRenderer(window *sdl.Window) (*sdl.Renderer, error) {
	// Already locked to main thread, no need to lock again

	// Get current video driver to determine best renderer type
	currentDriver, err := sdl.GetCurrentVideoDriver()
	if err != nil {
		currentDriver = "unknown"
	}

	var renderer *sdl.Renderer

	// Try hardware acceleration first if using GPU drivers
	if currentDriver == "kmsdrm" || currentDriver == "drm" || currentDriver == "cocoa" {
		log.Printf("Attempting hardware acceleration for %s driver", currentDriver)

		// For kmsdrm on Raspberry Pi, avoid VSync to prevent async flip errors
		var rendererFlags uint32 = sdl.RENDERER_ACCELERATED
		if currentDriver != "kmsdrm" {
			rendererFlags |= sdl.RENDERER_PRESENTVSYNC
		} else {
			log.Printf("Skipping VSync for kmsdrm to avoid VC4 async flip errors")
		}

		renderer, err = sdl.CreateRenderer(
			window,
			-1,
			rendererFlags,
		)
		if err != nil {
			log.Printf("Hardware acceleration failed, trying software: %v", err)
		} else {
			log.Printf("Hardware acceleration successful for %s driver", currentDriver)
		}
	}

	// Fallback to software renderer if hardware failed or for other drivers
	if renderer == nil {
		log.Printf("Using software renderer for %s driver", currentDriver)
		renderer, err = sdl.CreateRenderer(
			window,
			-1,
			sdl.RENDERER_SOFTWARE,
		)
		if err != nil {
			return nil, err
		}
	}

	// Enable alpha blending for UI overlays
	renderer.SetDrawBlendMode(sdl.BLENDMODE_BLEND)

	// Ensure renderer pointer is kept alive
	_ = unsafe.Pointer(renderer)
	runtime.GC()

	return renderer, nil
}

// runGameLoop executes the main SDL2 game loop
func runGameLoop(game *root.RootGame) {
	running := true
	frameTime := time.Second / targetFPS
	lastTime := time.Now()
	frameCount := 0

	for running {
		// Handle SDL2 events (already locked to main thread)
		for event := sdl.PollEvent(); event != nil; event = sdl.PollEvent() {
			switch event.(type) {
			case *sdl.QuitEvent:
				running = false
			}
		}

		// Update game logic
		if err := game.Update(); err != nil {
			log.Printf("Game update error: %v", err)
			running = false
			break
		}

		// Render frame
		if err := game.Draw(); err != nil {
			log.Printf("Game draw error: %v", err)
			running = false
			break
		}

		// Periodic garbage collection (every 60 frames)
		frameCount++
		if frameCount%60 == 0 {
			runtime.GC()
		}

		// Frame rate limiting
		elapsed := time.Since(lastTime)
		if elapsed < frameTime {
			time.Sleep(frameTime - elapsed)
		}
		lastTime = time.Now()
	}
}
