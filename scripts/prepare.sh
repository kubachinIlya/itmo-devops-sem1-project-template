#!/bin/bash
set -e

echo "Building Docker image"
docker build -t project-sem1:latest .

echo "Docker image built successfully"