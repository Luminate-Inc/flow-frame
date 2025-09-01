package videoFs

import (
	"art-frame/pkg/sharedTypes"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"

	"errors"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/s3"
)

// DownloadSegmentFromS3 downloads a limited number (count) of files from a collection starting at startIndex (0-based).
// It returns a slice with the absolute local paths of the downloaded files.
// The boolean in the second return value indicates whether we've reached the end of the collection.
func DownloadSegmentFromS3(collection sharedTypes.Collection, startIndex, count int) ([]string, bool, error) {
	log.Printf("DownloadSegmentFromS3 called | collection=%s | startIndex=%d | count=%d", collection.Title, startIndex, count)
	if count <= 0 {
		log.Printf("DownloadSegmentFromS3 early-return: non-positive count (%d)", count)
		return nil, false, nil
	}

	// Load credentials and region from environment variables
	region := os.Getenv("AWS_DEFAULT_REGION")
	accessKey := os.Getenv("AWS_ACCESS_KEY_ID")
	secretKey := os.Getenv("AWS_SECRET_ACCESS_KEY")

	if region == "" || accessKey == "" || secretKey == "" {
		return nil, false, errors.New("missing one or more required environment variables: AWS_DEFAULT_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY")
	}

	// Initialise AWS session
	sess, err := session.NewSession(&aws.Config{
		Region:      aws.String(region),
		Credentials: credentials.NewStaticCredentials(accessKey, secretKey, ""),
	})
	if err != nil {
		return nil, false, err
	}

	s3Client := s3.New(sess)

	// Ensure target directory exists
	targetDir := filepath.Join("assets", "videos")
	if err := os.MkdirAll(targetDir, os.ModePerm); err != nil {
		return nil, false, err
	}

	listInput := &s3.ListObjectsV2Input{
		Bucket: aws.String(collection.Bucket),
		Prefix: aws.String(collection.Folder),
	}

	// ------------------------------------------------------------
	// 1) LIST ALL NON-DIRECTORY OBJECT KEYS UNDER THE PREFIX
	// ------------------------------------------------------------
	var keys []string
	if err := s3Client.ListObjectsV2Pages(listInput, func(page *s3.ListObjectsV2Output, lastPage bool) bool {
		for _, obj := range page.Contents {
			if obj.Key == nil || strings.HasSuffix(*obj.Key, "/") {
				continue // skip empty keys or "directories"
			}
			keys = append(keys, *obj.Key)
		}
		return !lastPage
	}); err != nil {
		return nil, false, err
	}

	// ------------------------------------------------------------
	// 2) DETERMINE WHICH KEYS WE NEED FOR THIS SEGMENT
	// ------------------------------------------------------------
	if startIndex > len(keys) {
		// We asked for an index beyond the available items.
		return nil, true, errors.New(fmt.Sprintf("startIndex %d > len(keys) %d", startIndex, len(keys)))
	}

	endIndex := startIndex + count
	if endIndex > len(keys) {
		endIndex = len(keys)
	}
	segmentKeys := keys[startIndex:endIndex]
	// reachedEnd is true when we've reached or passed the final key in the collection.
	reachedEnd := endIndex >= len(keys)

	// ------------------------------------------------------------
	// 3) DOWNLOAD THE SELECTED OBJECTS
	// ------------------------------------------------------------
	paths := make([]string, 0, len(segmentKeys))
	for _, key := range segmentKeys {
		getInput := &s3.GetObjectInput{Bucket: aws.String(collection.Bucket), Key: aws.String(key)}
		result, err := s3Client.GetObject(getInput)
		if err != nil {
			log.Printf("failed to download %s: %v", key, err)
			continue // skip this object but keep going
		}
		func() { // anonymous func to ensure Body.Close per iteration
			defer result.Body.Close()

			localPath := filepath.Join(targetDir, filepath.Base(key))
			outFile, err := os.Create(localPath)
			if err != nil {
				log.Printf("failed to create file %s: %v", localPath, err)
				return
			}
			defer outFile.Close()

			if _, err := io.Copy(outFile, result.Body); err != nil {
				log.Printf("failed to write file %s: %v", localPath, err)
				return
			}
			paths = append(paths, localPath)
		}()
	}

	// If we ended up with zero paths after attempting to download, retry from beginning (once).
	if len(paths) == 0 && startIndex != 0 {
		return nil, false, errors.New(fmt.Sprintf("no videos downloaded for keys slice (start %d)", startIndex))
	}

	log.Printf("DownloadSegmentFromS3 completed | requested=%d | downloaded=%d | reachedEnd=%t", count, len(paths), reachedEnd)
	return paths, reachedEnd, nil
}
