#!/bin/bash 

set -e

echo "Starting application..."

 
go run main.go &
APP_PID=$!
 
sleep 5
 
if curl -s http://localhost:8080/api/v0/prices > /dev/null; then
    echo "Application started successfully on port 8080"
    echo "APP_PID=$APP_PID" > app.pid
    exit 0
else
    echo "Failed to start application"
    kill $APP_PID 2>/dev/null || true
    exit 1
fi