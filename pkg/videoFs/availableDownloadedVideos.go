package videoFs

import (
	"log"
	"os"
)

func AvailableDownloadedVideos() ([]string, error) {
	var videos []string

	// Read the assets/videos directory
	entries, err := os.ReadDir("assets/videos")
	if err != nil {
		log.Printf("Error reading assets/videos directory: %v", err)
		return nil, err
	}

	if len(entries) == 0 {
		panic("No downloaded videos found")
	}

	// Filter for mpg files
	for _, entry := range entries {
		if !entry.IsDir() {
			name := entry.Name()
			// Check if file has .mpg or .mpeg extension
			if len(name) > 4 && (name[len(name)-4:] == ".mpg" || name[len(name)-5:] == ".mpeg") {
				videos = append(videos, "assets/videos/"+name)
			}
		}
	}

	log.Printf("AvailableDownloadedVideos completed | found=%d video(s)", len(videos))
	return videos, nil
}
