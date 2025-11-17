package captiveportal

import (
	"fmt"
	"os/exec"
	"strings"
)

const (
	DefaultAPName  = "FlowFrame-AP"
	DefaultAPSSID  = "FlowFrame-Setup"
	DefaultAPIP    = "192.168.4.1"
	DefaultAPMask  = "255.255.255.0"
	DefaultDHCPStart = "192.168.4.2"
	DefaultDHCPEnd   = "192.168.4.20"
)

// detectWiFiInterface finds an available WiFi interface on the system
func detectWiFiInterface() (string, error) {
	// Try to list all WiFi devices using nmcli
	cmd := exec.Command("nmcli", "-t", "-f", "DEVICE,TYPE", "device")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("failed to list network devices: %w (output: %s)", err, string(output))
	}

	// Parse output to find wifi device
	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	for _, line := range lines {
		parts := strings.Split(line, ":")
		if len(parts) == 2 && parts[1] == "wifi" {
			return parts[0], nil
		}
	}

	return "", fmt.Errorf("no WiFi interface found")
}

// createAP creates a WiFi access point using NetworkManager
func createAP(iface, connectionName, ssid, ip string) error {
	// First, check if the connection already exists
	checkCmd := exec.Command("nmcli", "connection", "show", connectionName)
	if err := checkCmd.Run(); err == nil {
		// Connection exists, delete it first
		if err := destroyAP(connectionName); err != nil {
			return fmt.Errorf("failed to remove existing AP connection: %w", err)
		}
	}

	// Create WiFi hotspot using nmcli
	// This will automatically configure dnsmasq for DHCP/DNS
	cmd := exec.Command(
		"nmcli", "device", "wifi", "hotspot",
		"ifname", iface,
		"con-name", connectionName,
		"ssid", ssid,
		"password", "", // Empty password for open network
	)

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to create AP: %w (output: %s)", err, string(output))
	}

	// Modify the connection to use our specific IP address
	modifyCmd := exec.Command(
		"nmcli", "connection", "modify", connectionName,
		"ipv4.addresses", fmt.Sprintf("%s/24", ip),
		"ipv4.method", "shared",
	)

	output, err = modifyCmd.CombinedOutput()
	if err != nil {
		// Try to clean up the connection we just created
		_ = destroyAP(connectionName)
		return fmt.Errorf("failed to modify AP IP: %w (output: %s)", err, string(output))
	}

	// Bring up the connection
	upCmd := exec.Command("nmcli", "connection", "up", connectionName)
	output, err = upCmd.CombinedOutput()
	if err != nil {
		// Try to clean up
		_ = destroyAP(connectionName)
		return fmt.Errorf("failed to bring up AP: %w (output: %s)", err, string(output))
	}

	return nil
}

// destroyAP removes the access point connection
func destroyAP(connectionName string) error {
	// First try to bring down the connection
	downCmd := exec.Command("nmcli", "connection", "down", connectionName)
	_ = downCmd.Run() // Ignore errors here, connection might not be up

	// Delete the connection
	deleteCmd := exec.Command("nmcli", "connection", "delete", connectionName)
	output, err := deleteCmd.CombinedOutput()
	if err != nil {
		// Check if error is because connection doesn't exist
		if strings.Contains(string(output), "not found") ||
		   strings.Contains(string(output), "does not exist") {
			return nil // Connection doesn't exist, that's fine
		}
		return fmt.Errorf("failed to delete AP connection: %w (output: %s)", err, string(output))
	}

	return nil
}

// isAPRunning checks if the AP connection is currently active
func isAPRunning(connectionName string) bool {
	cmd := exec.Command("nmcli", "-t", "-f", "NAME,STATE", "connection", "show", "--active")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return false
	}

	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	for _, line := range lines {
		parts := strings.Split(line, ":")
		if len(parts) >= 2 && parts[0] == connectionName {
			return true
		}
	}

	return false
}
