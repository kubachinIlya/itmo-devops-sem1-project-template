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
	TotalCount      int     `json:"total_count"`
	DuplicatesCount int     `json:"duplicates_count"`
	TotalItems      int     `json:"total_items"`
	TotalCategories int     `json:"total_categories"`
	TotalPrice      float64 `json:"total_price"`
}

type PriceDB struct {
	ID         int       `json:"id"`
	Name       string    `json:"name"`
	Category   string    `json:"category"`
	Price      float64   `json:"price"`
	CreateDate time.Time `json:"create_date"`
}
