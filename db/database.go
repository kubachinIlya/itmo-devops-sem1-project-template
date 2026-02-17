package db

import (
	"database/sql"
	"fmt"
	"log"
	"os"

	"project_sem/models"

	_ "github.com/lib/pq"
)

func ConnectDB() (*sql.DB, error) {
	host := os.Getenv("POSTGRES_HOST")
	if host == "" {
		host = "localhost"
	}

	port := os.Getenv("POSTGRES_PORT")
	if port == "" {
		port = "5432"
	}

	connStr := fmt.Sprintf("postgres://validator:val1dat0r@%s:%s/project-sem-1?sslmode=disable",
		host, port)

	db, err := sql.Open("postgres", connStr)
	if err != nil {
		return nil, fmt.Errorf("error opening database: %v", err)
	}

	err = db.Ping()
	if err != nil {
		return nil, fmt.Errorf("error connecting to database: %v", err)
	}

	log.Println("Connected to database successfully")
	return db, nil
}

func CreateTable(db *sql.DB) error {
	// Исправлено: id теперь SERIAL (автоинкремент), убран PRIMARY KEY (id, create_date)
	query := `
	CREATE TABLE IF NOT EXISTS prices (
		id SERIAL PRIMARY KEY,
		name TEXT NOT NULL,
		category TEXT NOT NULL,
		price DECIMAL(10,2) NOT NULL,
		create_date DATE NOT NULL 
	)`

	_, err := db.Exec(query)
	if err != nil {
		return fmt.Errorf("error creating table: %v", err)
	}

	log.Println("Table 'prices' created or already exists")
	return nil
}

// InsertPriceItems вставляет данные и возвращает статистику
func InsertPriceItems(db *sql.DB, items []models.PriceItem) (models.PriceResponse, error) {
	var stats models.PriceResponse
	stats.TotalCount = len(items)

	// Начинаем транзакцию
	tx, err := db.Begin()
	if err != nil {
		return stats, fmt.Errorf("error starting transaction: %v", err)
	}
	defer tx.Rollback() // Откат в случае ошибки

	// Множество для проверки дубликатов в текущей партии
	itemKeys := make(map[string]bool)

	for _, item := range items {
		// Ключ для проверки дубликатов в текущей партии (по всем полям кроме id)
		key := fmt.Sprintf("%s-%s-%f-%s", item.Name, item.Category, item.Price, item.CreateDate)

		// Проверяем дубликаты в текущей партии
		if itemKeys[key] {
			stats.DuplicatesCount++
			continue
		}
		itemKeys[key] = true

		// Проверяем существование в БД по всем полям, дубликат - совпадение всех полей кроме id
		var exists bool
		err = tx.QueryRow(
			"SELECT EXISTS(SELECT 1 FROM prices WHERE name = $1 AND category = $2 AND price = $3 AND create_date = $4)",
			item.Name, item.Category, item.Price, item.CreateDate,
		).Scan(&exists)

		if err != nil {
			return stats, fmt.Errorf("error checking existence: %v", err)
		}

		if exists {
			stats.DuplicatesCount++
			continue
		}

		// Вставляем новую запись id не передаем
		_, err = tx.Exec(
			"INSERT INTO prices (name, category, price, create_date) VALUES ($1, $2, $3, $4)",
			item.Name, item.Category, item.Price, item.CreateDate,
		)

		if err != nil {
			return stats, fmt.Errorf("error inserting item: %v", err)
		}

		stats.TotalItems++
	}

	// Считаем статистику по всей БД после вставок
	err = tx.QueryRow("SELECT COUNT(*) FROM prices").Scan(&stats.TotalCount)
	if err != nil {
		return stats, fmt.Errorf("error getting total count: %v", err)
	}

	err = tx.QueryRow("SELECT COUNT(DISTINCT category) FROM prices").Scan(&stats.TotalCategories)
	if err != nil {
		return stats, fmt.Errorf("error getting categories count: %v", err)
	}

	err = tx.QueryRow("SELECT COALESCE(SUM(price), 0) FROM prices").Scan(&stats.TotalPrice)
	if err != nil {
		return stats, fmt.Errorf("error getting total price: %v", err)
	}

	// Подтверждаем транзакцию
	err = tx.Commit()
	if err != nil {
		return stats, fmt.Errorf("error committing transaction: %v", err)
	}

	return stats, nil
}

// GetPricesWithFilters получает данные с фильтрацией
func GetPricesWithFilters(db *sql.DB, start, end string, min, max float64) ([]models.PriceDB, error) {
	query := `
		SELECT id, name, category, price, create_date 
		FROM prices 
		WHERE 1=1
	`
	args := []interface{}{}
	argNum := 1

	if start != "" {
		query += fmt.Sprintf(" AND create_date >= $%d", argNum)
		args = append(args, start)
		argNum++
	}

	if end != "" {
		query += fmt.Sprintf(" AND create_date <= $%d", argNum)
		args = append(args, end)
		argNum++
	}

	if min > 0 {
		query += fmt.Sprintf(" AND price >= $%d", argNum)
		args = append(args, min)
		argNum++
	}

	if max > 0 {
		query += fmt.Sprintf(" AND price <= $%d", argNum)
		args = append(args, max)
		argNum++
	}

	query += " ORDER BY create_date, id"

	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("error querying database: %v", err)
	}
	defer rows.Close()

	var prices []models.PriceDB
	for rows.Next() {
		var p models.PriceDB
		err := rows.Scan(&p.ID, &p.Name, &p.Category, &p.Price, &p.CreateDate)
		if err != nil {
			return nil, fmt.Errorf("error scanning row: %v", err)
		}
		prices = append(prices, p)
	}

	// Проверяем ошибки после завершения rows.Next()
	if err = rows.Err(); err != nil {
		return nil, fmt.Errorf("error iterating rows: %v", err)
	}

	return prices, nil
}
