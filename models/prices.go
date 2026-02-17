package models

import (
	"time"
)

type PriceItem struct {
	ID         int
	Name       string
	Category   string
	Price      float64
	CreateDate string
}

type PriceResponse struct {
	TotalCount      int     `json:"total_count"`      // Общее количество строк в исходном файле
	DuplicatesCount int     `json:"duplicates_count"` // Количество дубликатов во входных данных и в СУБД
	TotalItems      int     `json:"total_items"`      // Количество успешно добавленных элементов
	TotalCategories int     `json:"total_categories"` // Общее количество категорий по всей БД
	TotalPrice      float64 `json:"total_price"`      // Суммарная стоимость по всей БД
}

type PriceDB struct {
	ID         int       `json:"id"`
	Name       string    `json:"name"`
	Category   string    `json:"category"`
	Price      float64   `json:"price"`
	CreateDate time.Time `json:"create_date"`
}
