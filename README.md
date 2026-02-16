Финальный проект 1 семестра (Сложный уровень)
REST API сервис для загрузки и выгрузки данных о ценах с валидацией и хранением в PostgreSQL.

Технологии
Backend: Go 1.23

База данных: PostgreSQL 15

Контейнеризация: Docker

Облако: Yandex Cloud

CI/CD: GitHub Actions

Требования к системе
ОС: Windows/Linux/macOS (для локального запуска)

Go: версия 1.23 или выше

PostgreSQL: версия 15 или выше

Docker: версия 24.0 или выше (для контейнеризации)

Yandex Cloud CLI: для деплоя в облако

ОЗУ: минимум 4GB свободной памяти

Диск: минимум 10GB свободного места

Эндпоинты
POST /api/v0/prices?type=zip
Загружает архив с данными и сохраняет в БД.

Параметры:

type - тип архива: zip (по умолчанию) или tar

Тело запроса: ZIP/TAR архив с файлом data.csv

Валидация:

Проверка на дубликаты (id + create_date)

Корректность формата даты (YYYY-MM-DD)

Положительная цена

Непустые name и category

Ответ:

json
{
  "total_count": 123,
  "duplicates_count": 20,
  "total_items": 100,
  "total_categories": 15,
  "total_price": 100000
}
GET /api/v0/prices?start=2024-01-01&end=2024-01-31&min=300&max=1000
Выгружает данные с фильтрацией в ZIP архиве.

Параметры (опциональны):

start - начальная дата (YYYY-MM-DD)

end - конечная дата (YYYY-MM-DD)

min - минимальная цена

max - максимальная цена

Ответ: ZIP архив с файлом data.csv

Установка и запуск
Локальный запуск
bash
# Клонирование репозитория
git clone <url-репозитория>
cd itmo-devops-sem1-project-template

# Установка зависимостей
go mod download

# Настройка PostgreSQL
sudo -u postgres psql
CREATE DATABASE "project-sem-1";
CREATE USER validator WITH PASSWORD 'val1dat0r';
GRANT ALL PRIVILEGES ON DATABASE "project-sem-1" TO validator;
\q

# Запуск сервера
go run main.go
Запуск через Docker
bash
# Сборка образа
docker build -t devops-app .

# Запуск контейнера
docker run -p 8080:8080 --network host devops-app
Запуск в Yandex Cloud
bash
# Настройка Yandex Cloud CLI
yc init

# Запуск скрипта деплоя
./scripts/run.sh
Скрипты
Скрипт	Назначение
scripts/prepare.sh	Сборка Docker-образа
scripts/run.sh	Создание VM в Yandex Cloud и деплой
scripts/tests.sh [1-3]	Запуск тестов (1 - простой, 2 - продвинутый, 3 - сложный уровень)
Тестирование
Структура тестовых данных
Директория sample_data содержит пример данных:

text
sample_data/
└── data.csv  # Тестовый файл с ценами
Запуск тестов
bash
# Простой уровень
./scripts/tests.sh 1

# Продвинутый уровень
./scripts/tests.sh 2

# Сложный уровень
./scripts/tests.sh 3
Результаты тестирования
Приложение успешно проходит все уровни тестирования:

✅ POST запросы с ZIP/TAR архивами

✅ Валидация данных и обработка дубликатов

✅ GET запросы с фильтрацией

✅ Работа с PostgreSQL

✅ Деплой в Yandex Cloud

CI/CD
В проекте настроен GitHub Actions, который:

Запускает тесты для всех уровней

Собирает Docker-образ

Деплоит приложение в Yandex Cloud

Контакты
По вопросам обращаться:

Разработчик: Илья Кубашин mirretty@gmail.com
