#!/bin/bash
set -e

echo "=== Подготовка окружения (сложный уровень) ==="

# Сборка Docker образа
echo "Сборка Docker образа..."
docker build -t devops-project:latest .

echo " Docker образ собран успешно"