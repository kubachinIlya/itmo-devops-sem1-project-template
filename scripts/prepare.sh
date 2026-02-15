#!/bin/bash 

set -e

echo "Installing dependencies..."
go mod download

echo "Building application..."
go build -o app main.go

echo "Waiting for PostgreSQL..."
for i in {1..30}; do
    if pg_isready -h localhost -U validator -d project-sem-1; then
        echo "PostgreSQL is ready"
        break
    fi
    echo "Waiting for PostgreSQL... $i/30"
    sleep 1
done

echo "Prepare completed"