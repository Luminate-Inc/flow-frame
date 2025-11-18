package captiveportal

import (
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/skip2/go-qrcode"
)

// Portal manages the complete captive portal system
type Portal struct {
	server        *WebServer
	isRunning     bool
	mu            sync.RWMutex
	apName        string
	apSSID        string
	apIP          string
	apPort        int
	wifiInterface string
	qrCodeData    []byte
	onConnectCallback func() // Called when WiFi connection succeeds
}

// NewPortal creates a new captive portal instance
func NewPortal() (*Portal, error) {
	return &Portal{
		apName:    DefaultAPName,
		apSSID:    DefaultAPSSID,
		apIP:      DefaultAPIP,
		apPort:    8080,
		isRunning: false,
	}, nil
}

// Start starts the captive portal (AP + web server)
func (p *Portal) Start() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if p.isRunning {
		log.Println("Captive portal is already running")
		return nil
	}

	log.Println("Starting captive portal...")

	// Step 1: Detect WiFi interface
	iface, err := detectWiFiInterface()
	if err != nil {
		return fmt.Errorf("failed to detect WiFi interface: %w", err)
	}
	p.wifiInterface = iface
	log.Printf("Detected WiFi interface: %s", iface)

	// Step 2: Validate AP mode support
	if err := validateAPSupport(iface); err != nil {
		log.Printf("Warning: %v", err)
	}

	// Step 3: Create access point
	log.Printf("Creating access point '%s' on interface %s", p.apSSID, iface)
	if err := createAP(iface, p.apName, p.apSSID, p.apIP); err != nil {
		return fmt.Errorf("failed to create access point: %w", err)
	}
	log.Printf("Access point created successfully")

	// Step 4: Generate QR code
	url := fmt.Sprintf("http://%s:%d", p.apIP, p.apPort)
	qrCode, err := qrcode.Encode(url, qrcode.Medium, 200)
	if err != nil {
		// Cleanup AP on failure
		_ = destroyAP(p.apName)
		return fmt.Errorf("failed to generate QR code: %w", err)
	}
	p.qrCodeData = qrCode
	log.Printf("QR code generated for: %s", url)

	// Step 5: Start web server
	p.server = NewWebServer(p.apIP, p.apPort, p.handleWiFiConnect)
	if err := p.server.Start(); err != nil {
		// Cleanup AP on failure
		_ = destroyAP(p.apName)
		return fmt.Errorf("failed to start web server: %w", err)
	}
	log.Printf("Web server started on %s", url)

	p.isRunning = true
	log.Println("Captive portal started successfully")
	return nil
}

// Stop stops the captive portal (web server + AP)
func (p *Portal) Stop() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if !p.isRunning {
		return nil
	}

	log.Println("Stopping captive portal...")

	// Step 1: Stop web server
	if p.server != nil {
		if err := p.server.Stop(); err != nil {
			log.Printf("Error stopping web server: %v", err)
		}
	}

	// Step 2: Destroy access point
	if err := destroyAP(p.apName); err != nil {
		log.Printf("Error destroying access point: %v", err)
	}

	p.isRunning = false
	log.Println("Captive portal stopped")
	return nil
}

// IsRunning returns whether the portal is currently running
func (p *Portal) IsRunning() bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.isRunning
}

// GetQRCodePNG returns the QR code as PNG bytes
func (p *Portal) GetQRCodePNG() ([]byte, error) {
	p.mu.RLock()
	defer p.mu.RUnlock()

	if !p.isRunning {
		return nil, fmt.Errorf("portal is not running")
	}

	if p.qrCodeData == nil {
		return nil, fmt.Errorf("QR code not generated")
	}

	return p.qrCodeData, nil
}

// GetSSID returns the AP SSID
func (p *Portal) GetSSID() string {
	return p.apSSID
}

// GetURL returns the web portal URL
func (p *Portal) GetURL() string {
	return fmt.Sprintf("http://%s:%d", p.apIP, p.apPort)
}

// SetOnConnectCallback sets a callback function to be called when WiFi connection succeeds
func (p *Portal) SetOnConnectCallback(callback func()) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.onConnectCallback = callback
}

// handleWiFiConnect is called by the web server when a connection attempt is made
func (p *Portal) handleWiFiConnect(ssid, password string) error {
	log.Printf("Attempting to connect to WiFi: %s", ssid)

	// Use the connectToWiFi function from handlers.go
	if err := connectToWiFi(ssid, password); err != nil {
		return err
	}

	log.Printf("WiFi connection to %s successful", ssid)

	// Schedule delayed shutdown of captive portal
	// This gives the client time to see the success status before AP goes down
	go func() {
		log.Println("Scheduling captive portal shutdown in 10 seconds...")
		time.Sleep(10 * time.Second)

		log.Println("Stopping captive portal after successful WiFi connection")
		if err := p.Stop(); err != nil {
			log.Printf("Error stopping captive portal: %v", err)
		}

		// Trigger callback after shutdown
		p.mu.RLock()
		callback := p.onConnectCallback
		p.mu.RUnlock()

		if callback != nil {
			callback()
		}
	}()

	return nil
}

// CheckWiFiConnection checks if there's an active WiFi connection
func CheckWiFiConnection() (bool, string, error) {
	ssid, err := getCurrentWiFi()
	if err != nil {
		return false, "", err
	}

	if ssid == "" {
		return false, "", nil
	}

	return true, ssid, nil
}
