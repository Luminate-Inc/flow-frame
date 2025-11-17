package captiveportal

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"
)

// WebServer manages the HTTP server for the captive portal
type WebServer struct {
	server    *http.Server
	isRunning bool
	mu        sync.RWMutex
	ip        string
	port      int
	onConnect func(ssid, password string) error // Callback for WiFi connection
}

// NewWebServer creates a new web server instance
func NewWebServer(ip string, port int, onConnect func(ssid, password string) error) *WebServer {
	return &WebServer{
		ip:        ip,
		port:      port,
		onConnect: onConnect,
		isRunning: false,
	}
}

// Start starts the HTTP server
func (ws *WebServer) Start() error {
	ws.mu.Lock()
	defer ws.mu.Unlock()

	if ws.isRunning {
		return fmt.Errorf("web server already running")
	}

	mux := http.NewServeMux()

	// Register handlers
	mux.HandleFunc("/", ws.handleRoot)
	mux.HandleFunc("/scan", ws.handleScan)
	mux.HandleFunc("/connect", ws.handleConnect)
	mux.HandleFunc("/status", ws.handleStatus)

	addr := fmt.Sprintf("%s:%d", ws.ip, ws.port)
	ws.server = &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	ws.isRunning = true

	// Start server in goroutine
	go func() {
		log.Printf("Starting captive portal web server on %s", addr)
		if err := ws.server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("Web server error: %v", err)
			ws.mu.Lock()
			ws.isRunning = false
			ws.mu.Unlock()
		}
	}()

	return nil
}

// Stop gracefully shuts down the HTTP server
func (ws *WebServer) Stop() error {
	ws.mu.Lock()
	defer ws.mu.Unlock()

	if !ws.isRunning {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := ws.server.Shutdown(ctx); err != nil {
		return fmt.Errorf("failed to shutdown web server: %w", err)
	}

	ws.isRunning = false
	log.Println("Captive portal web server stopped")
	return nil
}

// IsRunning returns whether the server is currently running
func (ws *WebServer) IsRunning() bool {
	ws.mu.RLock()
	defer ws.mu.RUnlock()
	return ws.isRunning
}

// GetURL returns the full URL of the captive portal
func (ws *WebServer) GetURL() string {
	return fmt.Sprintf("http://%s:%d", ws.ip, ws.port)
}
