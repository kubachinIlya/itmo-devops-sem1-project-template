// main.go
package main

import (
	"log"
	"net/http"

	"project_sem/db"
	"project_sem/handlers"

	"github.com/gorilla/mux"
)

func main() {
	// Подключение к БД
	database, err := db.ConnectDB()
	if err != nil {
		log.Fatal(err)
	}
	defer database.Close()

	// Создание таблицы
	err = db.CreateTable(database)
	if err != nil {
		database.Close()
		log.Fatal(err)
	}

	// Создаем обработчик с БД
	priceHandler := &handlers.PriceHandler{DB: database}

	// Настройка роутера
	r := mux.NewRouter()
	r.HandleFunc("/api/v0/prices", priceHandler.HandlePricesPost).Methods("POST")
	r.HandleFunc("/api/v0/prices", priceHandler.HandlePricesGet).Methods("GET")

	log.Println("Server starting on :8080")
	log.Fatal(http.ListenAndServe(":8080", r))
}
