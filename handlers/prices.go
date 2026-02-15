// handlers/prices.go
package handlers

import (
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"project_sem/db"
	"project_sem/utils"
)

type PriceHandler struct {
	DB *sql.DB
}

func (h *PriceHandler) HandlePricesPost(w http.ResponseWriter, r *http.Request) {
	// Получаем тип архива
	archiveType := r.URL.Query().Get("type")
	if archiveType == "" {
		archiveType = "zip" // По умолчанию zip
	}

	// Проверяем поддерживаемый тип
	if archiveType != "zip" && archiveType != "tar" {
		http.Error(w, "Unsupported archive type. Use 'zip' or 'tar'", http.StatusBadRequest)
		return
	}

	// --- Определяем, откуда читать данные ---
	var archiveData []byte
	var err error

	// Проверяем Content-Type
	contentType := r.Header.Get("Content-Type")

	if strings.Contains(contentType, "multipart/form-data") {
		// Это запрос от тестов (форма с файлом)
		err = r.ParseMultipartForm(10 << 20) // 10 MB max
		if err != nil {
			http.Error(w, "Failed to parse multipart form: "+err.Error(), http.StatusBadRequest)
			return
		}

		file, _, err := r.FormFile("file") // Имя поля - "file"
		if err != nil {
			http.Error(w, "Failed to get file from form: "+err.Error(), http.StatusBadRequest)
			return
		}
		defer file.Close()

		archiveData, err = io.ReadAll(file)
		if err != nil {
			http.Error(w, "Failed to read uploaded file: "+err.Error(), http.StatusBadRequest)
			return
		}
	} else {
		// Это запрос с бинарными данными в теле
		archiveData, err = io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "Failed to read request body: "+err.Error(), http.StatusBadRequest)
			return
		}
		defer r.Body.Close()
	}

	if len(archiveData) == 0 {
		http.Error(w, "Empty request body or file", http.StatusBadRequest)
		return
	}

	// Пытаемся распаковать как архив
	csvData, err := utils.ExtractCSVFromArchive(archiveData, archiveType)
	if err != nil {
		// Если не получилось распаковать как архив, пробуем распарсить данные как CSV напрямую
		items, parseErr := utils.ParseCSV(archiveData)
		if parseErr != nil {
			http.Error(w, "Failed to process data: "+err.Error(), http.StatusBadRequest)
			return
		}

		// Вставляем данные в БД
		stats, insertErr := db.InsertPriceItems(h.DB, items)
		if insertErr != nil {
			http.Error(w, "Failed to insert data: "+insertErr.Error(), http.StatusInternalServerError)
			return
		}

		// Возвращаем результат
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(stats)
		return
	}

	// Если дошли сюда, значит архив успешно распакован
	items, err := utils.ParseCSV(csvData)
	if err != nil {
		http.Error(w, "Failed to parse CSV from archive: "+err.Error(), http.StatusBadRequest)
		return
	}

	// Вставляем данные в БД
	stats, err := db.InsertPriceItems(h.DB, items)
	if err != nil {
		http.Error(w, "Failed to insert data: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Возвращаем результат
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(stats)
}

func (h *PriceHandler) HandlePricesGet(w http.ResponseWriter, r *http.Request) {
	// Получаем параметры из запроса
	start := r.URL.Query().Get("start")
	end := r.URL.Query().Get("end")
	minStr := r.URL.Query().Get("min")
	maxStr := r.URL.Query().Get("max")

	// Парсим числовые параметры
	var min, max float64
	var err error

	if minStr != "" {
		min, err = strconv.ParseFloat(minStr, 64)
		if err != nil || min < 0 {
			http.Error(w, "Invalid min parameter", http.StatusBadRequest)
			return
		}
	}

	if maxStr != "" {
		max, err = strconv.ParseFloat(maxStr, 64)
		if err != nil || max < 0 {
			http.Error(w, "Invalid max parameter", http.StatusBadRequest)
			return
		}
	}

	// Проверяем даты
	if start != "" {
		_, err = time.Parse("2006-01-02", start)
		if err != nil {
			http.Error(w, "Invalid start date format. Use YYYY-MM-DD", http.StatusBadRequest)
			return
		}
	}

	if end != "" {
		_, err = time.Parse("2006-01-02", end)
		if err != nil {
			http.Error(w, "Invalid end date format. Use YYYY-MM-DD", http.StatusBadRequest)
			return
		}
	}

	// Получаем данные из БД
	prices, err := db.GetPricesWithFilters(h.DB, start, end, min, max)
	if err != nil {
		http.Error(w, "Failed to get data: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Создаем CSV
	csvData, err := utils.CreatePricesCSV(prices)
	if err != nil {
		http.Error(w, "Failed to create CSV: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Создаем ZIP
	zipData, err := utils.CreateZipFromCSV(csvData)
	if err != nil {
		http.Error(w, "Failed to create ZIP: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Отправляем ZIP
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", "attachment; filename=prices.zip")
	w.WriteHeader(http.StatusOK)
	w.Write(zipData)
}
