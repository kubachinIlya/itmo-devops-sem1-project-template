package utils

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"strings"
)

func ExtractCSVFromArchive(data []byte, archiveType string) ([]byte, error) {
	switch strings.ToLower(archiveType) {
	case "zip":
		return extractFromZip(data)
	case "tar":
		return extractFromTar(data)
	default:
		return nil, fmt.Errorf("unsupported archive type: %s", archiveType)
	}
}

func extractFromZip(data []byte) ([]byte, error) {
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, fmt.Errorf("error reading zip: %v", err)
	}

	// Ищем CSV файл
	for _, file := range reader.File {
		if strings.HasSuffix(strings.ToLower(file.Name), ".csv") {
			rc, err := file.Open()
			if err != nil {
				return nil, fmt.Errorf("error opening file in zip: %v", err)
			}
			defer rc.Close()

			csvData, err := io.ReadAll(rc)
			if err != nil {
				return nil, fmt.Errorf("error reading CSV from zip: %v", err)
			}
			return csvData, nil
		}
	}

	return nil, fmt.Errorf("no CSV file found in zip archive")
}

func extractFromTar(data []byte) ([]byte, error) {
	var tarReader *tar.Reader

	//  как gzip
	gzipReader, err := gzip.NewReader(bytes.NewReader(data))
	if err == nil {
		//  gzip
		defer gzipReader.Close()
		tarReader = tar.NewReader(gzipReader)
	} else {
		// tar
		tarReader = tar.NewReader(bytes.NewReader(data))
	}

	// Ищем CSV файл
	for {
		header, err := tarReader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("error reading tar: %v", err)
		}

		if strings.HasSuffix(strings.ToLower(header.Name), ".csv") {
			csvData, err := io.ReadAll(tarReader)
			if err != nil {
				return nil, fmt.Errorf("error reading CSV from tar: %v", err)
			}
			return csvData, nil
		}
	}

	return nil, fmt.Errorf("no CSV file found in tar archive")
}
