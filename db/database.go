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
	query := `
	CREATE TABLE IF NOT EXISTS prices (
		id INTEGER,
		name TEXT NOT NULL,
		category TEXT NOT NULL,
		price DECIMAL(10,2) NOT NULL,
		create_date DATE NOT NULL,
		PRIMARY KEY (id, create_date)
	)`

	_, err := db.Exec(query)
	if err != nil {
		return fmt.Errorf("error creating table: %v", err)
	}

	log.Println("Table 'prices' created or already exists")
	return nil
}

// InsertPriceItems вставляет данные и возвращает статистику
func InsertPriceItems(db *sql.DB, items []models.PriceItem) (stats models.PriceResponse, err error) {
	// Получаем текущую статистику до вставки
	var existingCount int
	err = db.QueryRow("SELECT COUNT(*) FROM prices").Scan(&existingCount)
	if err != nil {
		return stats, fmt.Errorf("error getting existing count: %v", err)
	}

	// Множество для проверки дубликатов в текущей партии
	itemKeys := make(map[string]bool)

	for _, item := range items {
		key := fmt.Sprintf("%d-%s", item.ID, item.CreateDate)

		// Проверяем дубликаты в текущей партии
		if itemKeys[key] {
			stats.DuplicatesCount++
			continue
		}
		itemKeys[key] = true

		// Проверяем существование в БД
		var exists bool
		err = db.QueryRow(
			"SELECT EXISTS(SELECT 1 FROM prices WHERE id = $1 AND create_date = $2)",
			item.ID, item.CreateDate,
		).Scan(&exists)

		if err != nil {
			log.Printf("Error checking existence: %v", err)
			continue
		}

		if exists {
			stats.DuplicatesCount++
			continue
		}

		// Вставляем новую запись
		_, err = db.Exec(
			"INSERT INTO prices (id, name, category, price, create_date) VALUES ($1, $2, $3, $4, $5)",
			item.ID, item.Name, item.Category, item.Price, item.CreateDate,
		)

		if err != nil {
			log.Printf("Error inserting item: %v", err)
			continue
		}

		stats.TotalItems++
		stats.TotalPrice += item.Price
	}

	// Получаем общее количество категорий
	err = db.QueryRow("SELECT COUNT(DISTINCT category) FROM prices").Scan(&stats.TotalCategories)
	if err != nil {
		log.Printf("Error getting categories count: %v", err)
	}

	stats.TotalCount = existingCount + stats.TotalItems
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

	return prices, nil
}
