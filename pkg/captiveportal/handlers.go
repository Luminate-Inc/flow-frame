package captiveportal

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os/exec"
	"strings"
	"sync"
	"time"
)

//go:embed wifi_page.html
var wifiPageHTML string

// Connection status tracking
var (
	connectionMu     sync.RWMutex
	connectionStatus = "idle" // idle, connecting, success, error
	connectionError  = ""
	connectedSSID    = ""
)

// handleRoot serves the main WiFi configuration page
func (ws *WebServer) handleRoot(w http.ResponseWriter, r *http.Request) {
	// Serve the embedded HTML page
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(wifiPageHTML))
}

// WiFiNetwork represents a scanned WiFi network
type WiFiNetwork struct {
	SSID     string `json:"ssid"`
	Signal   string `json:"signal"`
	Security string `json:"security"`
	IsOpen   bool   `json:"is_open"`
}

// handleScan returns a list of available WiFi networks
func (ws *WebServer) handleScan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	networks, err := scanWiFiNetworks()
	if err != nil {
		log.Printf("Failed to scan WiFi networks: %v", err)
		http.Error(w, fmt.Sprintf("Failed to scan networks: %v", err), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(networks)
}

// ConnectRequest represents the WiFi connection request
type ConnectRequest struct {
	SSID     string `json:"ssid"`
	Password string `json:"password"`
}

// handleConnect attempts to connect to a WiFi network
func (ws *WebServer) handleConnect(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req ConnectRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	if req.SSID == "" {
		http.Error(w, "SSID is required", http.StatusBadRequest)
		return
	}

	// Update status to connecting
	connectionMu.Lock()
	connectionStatus = "connecting"
	connectionError = ""
	connectedSSID = req.SSID
	connectionMu.Unlock()

	// Attempt connection in background
	go func() {
		err := ws.onConnect(req.SSID, req.Password)

		connectionMu.Lock()
		if err != nil {
			connectionStatus = "error"
			connectionError = err.Error()
			log.Printf("Failed to connect to %s: %v", req.SSID, err)
		} else {
			connectionStatus = "success"
			log.Printf("Successfully connected to %s", req.SSID)

			// Wait a bit before verifying
			time.Sleep(2 * time.Second)

			// Verify connection
			if current, err := getCurrentWiFi(); err == nil && current == req.SSID {
				log.Printf("Connection verified: %s", current)
			}
		}
		connectionMu.Unlock()
	}()

	// Return immediate response
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status": "connecting",
		"message": "Connection attempt started",
	})
}

// StatusResponse represents the connection status
type StatusResponse struct {
	Status       string `json:"status"`
	Error        string `json:"error,omitempty"`
	ConnectedTo  string `json:"connected_to,omitempty"`
}

// handleStatus returns the current connection status
func (ws *WebServer) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	connectionMu.RLock()
	response := StatusResponse{
		Status:      connectionStatus,
		Error:       connectionError,
		ConnectedTo: connectedSSID,
	}
	connectionMu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

// scanWiFiNetworks scans for available WiFi networks using nmcli
// This is a copy of the function from widgets/settings/wifi.go to avoid circular dependencies
func scanWiFiNetworks() ([]WiFiNetwork, error) {
	cmd := exec.Command("nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY", "dev", "wifi", "list")

	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("failed to scan WiFi networks: %w (output: %s)", err, string(output))
	}

	return parseWiFiNetworks(string(output)), nil
}

// parseWiFiNetworks parses nmcli output into WiFiNetwork structs
func parseWiFiNetworks(output string) []WiFiNetwork {
	lines := strings.Split(strings.TrimSpace(output), "\n")
	networks := make([]WiFiNetwork, 0, len(lines))

	// Track seen SSIDs to avoid duplicates
	seen := make(map[string]bool)

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		// Format: SSID:SIGNAL:SECURITY
		parts := strings.Split(line, ":")
		if len(parts) < 3 {
			continue
		}

		ssid := strings.TrimSpace(parts[0])
		signal := strings.TrimSpace(parts[1])
		security := strings.TrimSpace(parts[2])

		// Skip empty SSIDs (hidden networks)
		if ssid == "" {
			continue
		}

		// Skip duplicates
		if seen[ssid] {
			continue
		}
		seen[ssid] = true

		isOpen := security == ""

		networks = append(networks, WiFiNetwork{
			SSID:     ssid,
			Signal:   signal,
			Security: security,
			IsOpen:   isOpen,
		})
	}

	return networks
}

// getCurrentWiFi returns the currently connected WiFi network
func getCurrentWiFi() (string, error) {
	cmd := exec.Command("nmcli", "-t", "-f", "ACTIVE,SSID", "dev", "wifi")

	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("failed to get current WiFi: %w", err)
	}

	lines := strings.Split(string(output), "\n")
	for _, line := range lines {
		if strings.HasPrefix(line, "yes:") {
			return strings.TrimPrefix(line, "yes:"), nil
		}
	}

	return "", nil
}

// connectToWiFi connects to a WiFi network using nmcli
func connectToWiFi(ssid, password string) error {
	var cmd *exec.Cmd

	if password == "" {
		// Connect to open network
		cmd = exec.Command("sudo", "nmcli", "dev", "wifi", "connect", ssid)
	} else {
		// Connect to secured network
		cmd = exec.Command("sudo", "nmcli", "dev", "wifi", "connect", ssid, "password", password)
	}

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to connect to %s: %w (output: %s)", ssid, err, string(output))
	}

	return nil
}
