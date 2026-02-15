package utils

import (
	"bytes"
	"encoding/csv"
	"fmt"
	"strconv"
	"strings"
	"time"

	"project_sem/models"
)

// ParseCSV парсит CSV данные и возвращает слайс PriceItem
func ParseCSV(data []byte) ([]models.PriceItem, error) {
	//  reader для CSV
	reader := csv.NewReader(bytes.NewReader(data))

	// Читаем все записи
	records, err := reader.ReadAll()
	if err != nil {
		return nil, fmt.Errorf("error reading CSV: %v", err)
	}

	// Проверяем, что есть хотя бы заголовок
	if len(records) < 1 {
		return nil, fmt.Errorf("empty CSV file")
	}

	// Проверяем заголовки
	headers := records[0]
	expectedHeaders := []string{"id", "name", "category", "price", "create_date"}
	for i, h := range expectedHeaders {
		if i >= len(headers) || strings.ToLower(headers[i]) != h {
			return nil, fmt.Errorf("invalid CSV headers: expected %v, got %v", expectedHeaders, headers)
		}
	}

	// Если нет данных кроме заголовка
	if len(records) < 2 {
		return []models.PriceItem{}, nil
	}

	var items []models.PriceItem
	validRows := 0

	// Парсим данные  (индекс 1)
	for i, record := range records[1:] {
		rowNum := i + 2 // +2 потому что i начинается с 0  а строки с 1 + заголовок

		// Проверяем количество колонок
		if len(record) < 5 {
			fmt.Printf("Warning: row %d has insufficient columns, skipping\n", rowNum)
			continue
		}

		// Парсим ID
		id, err := strconv.Atoi(strings.TrimSpace(record[0]))
		if err != nil {
			fmt.Printf("Warning: row %d has invalid ID '%s', skipping\n", rowNum, record[0])
			continue
		}

		// Проверяем Name
		name := strings.TrimSpace(record[1])
		if name == "" {
			fmt.Printf("Warning: row %d has empty name, skipping\n", rowNum)
			continue
		}

		// Проверяем Category
		category := strings.TrimSpace(record[2])
		if category == "" {
			fmt.Printf("Warning: row %d has empty category, skipping\n", rowNum)
			continue
		}

		// Парсим Price
		price, err := strconv.ParseFloat(strings.TrimSpace(record[3]), 64)
		if err != nil || price < 0 {
			fmt.Printf("Warning: row %d has invalid price '%s', skipping\n", rowNum, record[3])
			continue
		}

		// Проверяем формат даты
		dateStr := strings.TrimSpace(record[4])
		_, err = time.Parse("2006-01-02", dateStr)
		if err != nil {
			fmt.Printf("Warning: row %d has invalid date '%s', skipping\n", rowNum, dateStr)
			continue
		}

		item := models.PriceItem{
			ID:         id,
			Name:       name,
			Category:   category,
			Price:      price,
			CreateDate: dateStr,
		}

		items = append(items, item)
		validRows++
	}

	fmt.Printf("Parsed %d valid rows out of %d total data rows\n", validRows, len(records)-1)
	return items, nil
}
