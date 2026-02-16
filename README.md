# Финальный проект 1 семестра

REST API сервис для загрузки и выгрузки данных о ценах.

## Требования к системе

- **ОС**: Linux, macOS, Windows (с поддержкой Docker)
    
- **Docker** 20.10+
    
- **Go** 1.23+ (для локального запуска)
    
- **PostgreSQL** 15+ (для локального запуска)
    
- **Yandex Cloud CLI** (для деплоя в облако)
    

## Установка и запуск

**Локальный запуск:**

bash

go mod download
go run main.go

**Запуск в Docker:**

bash

docker build -t devops-app .
docker run -p 8080:8080 --network host devops-app

**Деплой в Yandex Cloud:**

bash

chmod +x scripts/*.sh
./scripts/run.sh

## Тестирование

**sample_data.zip** - тестовый архив с данными, разархивированная версия лежит в `sample_data/`

Запуск тестов для разных уровней сложности:

bash

./scripts/tests.sh 1  # простой уровень
./scripts/tests.sh 2  # продвинутый уровень  
./scripts/tests.sh 3  # сложный уровень

Тесты проверяют:

- ✅ POST загрузку ZIP/TAR архивов
    
- ✅ Валидацию данных и обработку дубликатов
    
- ✅ GET выгрузку с фильтрацией по датам и цене
    
- ✅ Работу с PostgreSQL


## Контакт
- mirretty@gmail.com - Кубашин Илья Александрович
