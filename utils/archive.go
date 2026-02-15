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
	// Проверяем, что это действительно ZIP архив
	if len(data) < 4 {
		return nil, fmt.Errorf("data too small to be a zip file")
	}

	// Проверяем сигнатуру ZIP файла (PK)
	if data[0] != 0x50 || data[1] != 0x4B {
		return nil, fmt.Errorf("not a valid zip file: invalid header")
	}

	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, fmt.Errorf("error reading zip: %v", err)
	}

	// Ищем CSV файл в архиве
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
	var fileReader io.Reader = bytes.NewReader(data)

	// Проверяем сигнатуру gzip (0x1F 0x8B)
	if len(data) > 2 && data[0] == 0x1F && data[1] == 0x8B {
		// Это gzip сжатый tar
		gzipReader, err := gzip.NewReader(bytes.NewReader(data))
		if err != nil {
			return nil, fmt.Errorf("error reading gzip: %v", err)
		}
		defer gzipReader.Close()
		fileReader = gzipReader
	}

	// Создаем tar reader
	tarReader = tar.NewReader(fileReader)

	// Ищем CSV файл
	for {
		header, err := tarReader.Next()
		if err == io.EOF {
			break // Конец архива
		}
		if err != nil {
			return nil, fmt.Errorf("error reading tar: %v", err)
		}

		// Пропускаем директории
		if header.Typeflag == tar.TypeDir {
			continue
		}

		// Проверяем, что это CSV файл
		if strings.HasSuffix(strings.ToLower(header.Name), ".csv") {
			// Читаем содержимое файла
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
