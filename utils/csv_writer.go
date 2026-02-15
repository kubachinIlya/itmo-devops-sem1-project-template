package utils

import (
	"archive/zip"
	"bytes"
	"encoding/csv"
	"project_sem/models"
	"strconv"
)

func CreatePricesCSV(prices []models.PriceDB) ([]byte, error) {
	var buf bytes.Buffer
	writer := csv.NewWriter(&buf)

	// Записываем заголовок
	err := writer.Write([]string{"id", "name", "category", "price", "create_date"})
	if err != nil {
		return nil, err
	}

	// Записываем данные
	for _, p := range prices {
		row := []string{
			strconv.Itoa(p.ID),
			p.Name,
			p.Category,
			strconv.FormatFloat(p.Price, 'f', 2, 64),
			p.CreateDate.Format("2006-01-02"),
		}
		err = writer.Write(row)
		if err != nil {
			return nil, err
		}
	}

	writer.Flush()
	return buf.Bytes(), nil
}

func CreateZipFromCSV(csvData []byte) ([]byte, error) {
	var buf bytes.Buffer
	zipWriter := zip.NewWriter(&buf)

	// Создаем файл в архиве
	f, err := zipWriter.Create("data.csv")
	if err != nil {
		return nil, err
	}

	// Записываем CSV данные
	_, err = f.Write(csvData)
	if err != nil {
		return nil, err
	}

	err = zipWriter.Close()
	if err != nil {
		return nil, err
	}

	return buf.Bytes(), nil
}
