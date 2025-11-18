package captiveportal

import (
	"fmt"
	"log"
	"os/exec"
	"strings"
	"time"
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

// disconnectInterface disconnects any active connections on the WiFi interface
func disconnectInterface(iface string) error {
	// Check if interface has any active connections
	cmd := exec.Command("nmcli", "-t", "-f", "DEVICE,STATE,CONNECTION", "device")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to check device state: %w", err)
	}

	log.Printf("Device states:\n%s", string(output))

	// Parse output to check if our interface is connected
	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	isConnected := false
	deviceState := ""
	for _, line := range lines {
		parts := strings.Split(line, ":")
		if len(parts) >= 2 && parts[0] == iface {
			deviceState = parts[1]
			log.Printf("Interface %s state: %s", iface, deviceState)
			if deviceState == "connected" || deviceState == "connecting" {
				isConnected = true
				break
			}
			// Check if unmanaged
			if deviceState == "unmanaged" {
				log.Printf("WARNING: Interface %s is unmanaged by NetworkManager", iface)
				log.Printf("Attempting to set as managed...")
				manageCmd := exec.Command("nmcli", "device", "set", iface, "managed", "yes")
				if manageOutput, manageErr := manageCmd.CombinedOutput(); manageErr != nil {
					log.Printf("Failed to set managed state: %v (output: %s)", manageErr, string(manageOutput))
				} else {
					log.Printf("Successfully set %s to managed", iface)
					time.Sleep(2 * time.Second) // Wait for state to settle
				}
				return nil
			}
		}
	}

	if !isConnected {
		// Interface not connected, nothing to do
		log.Printf("Interface %s is not connected (state: %s)", iface, deviceState)
		return nil
	}

	// Disconnect the interface
	log.Printf("WiFi interface %s is connected, disconnecting...", iface)
	cmd = exec.Command("nmcli", "device", "disconnect", iface)
	output, err = cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to disconnect %s: %w (output: %s)", iface, err, string(output))
	}

	log.Printf("Successfully disconnected %s", iface)

	// Wait a moment for the interface to fully disconnect
	time.Sleep(2 * time.Second)

	return nil
}

// validateAPSupport checks if the WiFi interface supports AP/hotspot mode
func validateAPSupport(iface string) error {
	// Check if iw is available
	cmd := exec.Command("which", "iw")
	if err := cmd.Run(); err != nil {
		// iw not available, skip validation (assume nmcli will handle it)
		return nil
	}

	// Check supported modes using iw
	cmd = exec.Command("iw", "phy")
	output, err := cmd.CombinedOutput()
	if err != nil {
		// If iw fails, we'll let nmcli attempt it anyway
		return nil
	}

	// Look for AP mode support
	outputStr := string(output)
	if strings.Contains(outputStr, "* AP") || strings.Contains(outputStr, "AP/VLAN") {
		return nil
	}

	// Try alternative check with iw dev
	cmd = exec.Command("iw", "dev", iface, "info")
	if err := cmd.Run(); err == nil {
		// If we can get device info, AP support is likely available
		// (most modern WiFi adapters support it)
		return nil
	}

	return fmt.Errorf("WiFi interface %s may not support AP mode - this is a warning, attempting anyway", iface)
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

	// Disconnect any active connections on the interface
	// This is critical - you can't create a hotspot while connected to a network
	if err := disconnectInterface(iface); err != nil {
		return fmt.Errorf("failed to prepare interface for AP: %w", err)
	}

	// Create WiFi hotspot using nmcli
	// This will automatically configure dnsmasq for DHCP/DNS
	// No password parameter = open network
	cmd := exec.Command(
		"nmcli", "device", "wifi", "hotspot",
		"ifname", iface,
		"con-name", connectionName,
		"ssid", ssid,
	)

	// Log the exact command for debugging
	log.Printf("Executing: nmcli device wifi hotspot ifname %s con-name %s ssid %s", iface, connectionName, ssid)

	output, err := cmd.CombinedOutput()
	log.Printf("nmcli hotspot output: %s", string(output))
	if err != nil {
		// Provide helpful context for common errors
		errMsg := string(output)
		if strings.Contains(errMsg, "failed to setup") {
			return fmt.Errorf("failed to create AP: interface may be busy or in wrong state (try running 'nmcli device set %s managed yes'): %w (output: %s)", iface, err, errMsg)
		}
		if strings.Contains(errMsg, "not found") {
			return fmt.Errorf("failed to create AP: WiFi device not found: %w (output: %s)", err, errMsg)
		}
		if strings.Contains(errMsg, "No suitable device") {
			return fmt.Errorf("failed to create AP: interface %s cannot create hotspot: %w (output: %s)", iface, err, errMsg)
		}
		return fmt.Errorf("failed to create AP: %w (output: %s)", err, errMsg)
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

	// Verify the connection is actually active
	if !isAPRunning(connectionName) {
		_ = destroyAP(connectionName)
		return fmt.Errorf("AP connection brought up but not active")
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
