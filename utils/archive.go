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
	if len(data) < 4 {
		return nil, fmt.Errorf("data too small to be a zip file")
	}

	// Проверяем сигнатуру ZIP (PK)
	if data[0] != 0x50 || data[1] != 0x4B {
		return nil, fmt.Errorf("not a valid zip file: invalid header")
	}

	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, fmt.Errorf("error reading zip: %v", err)
	}

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
	if len(data) < 2 {
		return nil, fmt.Errorf("data too small to be a tar file")
	}

	var tarReader *tar.Reader

	// Проверяем, является ли файл gzip сжатым
	if len(data) > 2 && data[0] == 0x1F && data[1] == 0x8B {
		// Это gzip
		gzipReader, err := gzip.NewReader(bytes.NewReader(data))
		if err != nil {
			return nil, fmt.Errorf("error creating gzip reader: %v", err)
		}
		defer gzipReader.Close()
		tarReader = tar.NewReader(gzipReader)
	} else {
		// Обычный tar
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

		// Пропускаем директории
		if header.Typeflag == tar.TypeDir {
			continue
		}

		// Ищем CSV файл
		if strings.HasSuffix(strings.ToLower(header.Name), ".csv") {
			var buf bytes.Buffer
			_, err = io.Copy(&buf, tarReader)
			if err != nil {
				return nil, fmt.Errorf("error reading CSV from tar: %v", err)
			}
			return buf.Bytes(), nil
		}
	}

	return nil, fmt.Errorf("no CSV file found in tar archive")
}
