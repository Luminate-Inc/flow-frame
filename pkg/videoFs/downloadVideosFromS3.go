package videoFs

import (
	"flow-frame/pkg/sharedTypes"
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

/*
Download the content from the s3 bucket
*/
func DownloadVideosFromS3(activeCollection sharedTypes.Collection) ([]string, error) {
	// Verbose logging to trace S3 downloads
	log.Printf("DownloadVideosFromS3 called | collection=%s", activeCollection.Title)
	// Load credentials and region from environment variables
	region := os.Getenv("AWS_DEFAULT_REGION")
	accessKey := os.Getenv("AWS_ACCESS_KEY_ID")
	secretKey := os.Getenv("AWS_SECRET_ACCESS_KEY")

	if region == "" || accessKey == "" || secretKey == "" {
		return nil, errors.New("missing one or more required environment variables: AWS_DEFAULT_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY")
	}

	// Initialise AWS session
	sess, err := session.NewSession(&aws.Config{
		Region:      aws.String(region),
		Credentials: credentials.NewStaticCredentials(accessKey, secretKey, ""),
	})
	if err != nil {
		return nil, err
	}

	s3Client := s3.New(sess)

	// Ensure target directory exists
	targetDir := filepath.Join("assets", "videos")
	if err := os.MkdirAll(targetDir, os.ModePerm); err != nil {
		return nil, err
	}

	// List all objects under the specified folder (prefix)
	listInput := &s3.ListObjectsV2Input{
		Bucket: aws.String(activeCollection.Bucket),
		Prefix: aws.String(activeCollection.Folder),
	}

	var filePaths []string

	err = s3Client.ListObjectsV2Pages(listInput, func(page *s3.ListObjectsV2Output, lastPage bool) bool {
		for _, obj := range page.Contents {
			if obj.Key == nil {
				continue
			}

			// Skip if the key represents a "directory" (S3 keys ending with '/')
			if strings.HasSuffix(*obj.Key, "/") {
				continue
			}

			// Download each object
			getInput := &s3.GetObjectInput{
				Bucket: aws.String(activeCollection.Bucket),
				Key:    aws.String(*obj.Key),
			}

			result, err := s3Client.GetObject(getInput)
			if err != nil {
				log.Printf("failed to download %s: %v", *obj.Key, err)
				continue // skip this file but continue processing others
			}
			defer result.Body.Close()

			localPath := filepath.Join(targetDir, filepath.Base(*obj.Key))
			outFile, err := os.Create(localPath)
			if err != nil {
				log.Printf("failed to create file %s: %v", localPath, err)
				continue
			}

			_, err = io.Copy(outFile, result.Body)
			outFile.Close()
			if err != nil {
				log.Printf("failed to write file %s: %v", localPath, err)
				continue
			}

			filePaths = append(filePaths, localPath)
		}
		return true
	})

	if err != nil {
		return nil, err
	}

	log.Printf("DownloadVideosFromS3 completed | downloaded=%d file(s) from collection %s", len(filePaths), activeCollection.Title)
	return filePaths, nil
}
