package settings

import (
	"fmt"
	"os/exec"
	"strings"
)

// ScanWiFiNetworks scans for available WiFi networks using nmcli
func ScanWiFiNetworks() ([]Item, error) {
	// Execute nmcli command to list WiFi networks
	// -t: terse output for easier parsing
	// -f: specify fields (SSID, signal strength, security)
	cmd := exec.Command("nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY", "dev", "wifi", "list")

	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("failed to scan WiFi networks: %w (output: %s)", err, string(output))
	}

	return parseWiFiNetworks(string(output)), nil
}

// parseWiFiNetworks parses nmcli output into menu items
func parseWiFiNetworks(output string) []Item {
	lines := strings.Split(strings.TrimSpace(output), "\n")
	items := make([]Item, 0, len(lines))

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

		// Build title with security indicator
		title := ssid
		if security == "" {
			title = ssid + " (Open)"
		}

		// Build value with signal strength
		value := signal + "%"

		items = append(items, Item{
			Title: title,
			Value: value,
		})
	}

	return items
}

// ConnectToWiFi connects to a WiFi network using nmcli
func ConnectToWiFi(ssid, password string) error {
	var cmd *exec.Cmd

	// Clean SSID (remove security indicators)
	cleanSSID := strings.TrimSuffix(ssid, " (Open)")

	if password == "" {
		// Connect to open network
		cmd = exec.Command("sudo", "nmcli", "dev", "wifi", "connect", cleanSSID)
	} else {
		// Connect to secured network
		cmd = exec.Command("sudo", "nmcli", "dev", "wifi", "connect", cleanSSID, "password", password)
	}

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to connect to %s: %w (output: %s)", cleanSSID, err, string(output))
	}

	return nil
}

// GetCurrentWiFi returns the currently connected WiFi network
func GetCurrentWiFi() (string, error) {
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
