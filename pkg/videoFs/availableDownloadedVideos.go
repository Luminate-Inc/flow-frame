package videoFs

import (
	"log"
	"os"
)

func AvailableDownloadedVideos() ([]string, error) {
	var videos []string

	// Helper function to scan a directory for video files
	scanDir := func(dirPath string) {
		entries, err := os.ReadDir(dirPath)
		if err != nil {
			log.Printf("Error reading %s directory: %v", dirPath, err)
			return
		}

		// Filter for mpg files
		for _, entry := range entries {
			if !entry.IsDir() {
				name := entry.Name()
				// Check if file has .mpg or .mpeg extension
				if len(name) > 4 && (name[len(name)-4:] == ".mpg" || name[len(name)-5:] == ".mpeg") {
					videos = append(videos, dirPath+"/"+name)
				}
			}
		}
	}

	// Scan both directories
	scanDir("assets/tmp")
	scanDir("assets/stock")
	scanDir("assets")

	if len(videos) == 0 {
		panic("No downloaded videos found")
	}

	log.Printf("AvailableDownloadedVideos completed | found=%d video(s)", len(videos))
	return videos, nil
}
