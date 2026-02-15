#!/bin/bash
set -e

echo "=== Deploying to Yandex Cloud (Complex Level) ==="

# Конфигурация из GitHub Secrets
FOLDER_ID="${YC_FOLDER_ID:-b1gg9v1869p6b25d54uq}"
SUBNET_ID="${YC_SUBNET_ID:-e9b5mhgqb5a7h1vphdp3}"
VM_NAME="project-sem1-vm-$(date +%s)"  # Уникальное имя с timestamp
VM_ZONE="ru-central1-a"

# Создаем временный файл для SSH ключа
SSH_KEY_FILE=$(mktemp)
echo "$YC_SSH_PRIVATE_KEY" > "$SSH_KEY_FILE"
chmod 600 "$SSH_KEY_FILE"

# Проверка наличия yc CLI
if ! command -v yc &> /dev/null; then
    echo "Error: yc CLI not found. Please install it first."
    exit 1
fi

# Проверка наличия SSH ключа
if [ -z "$YC_SSH_PUBLIC_KEY" ]; then
    echo "Error: SSH public key not found in environment"
    exit 1
fi

echo "Creating VM in Yandex Cloud..."

# Создаем виртуальную машину
VM_ID=$(yc compute instance create \
  --name $VM_NAME \
  --zone $VM_ZONE \
  --folder-id $FOLDER_ID \
  --platform standard-v3 \
  --cores 2 \
  --memory 4GB \
  --create-boot-disk image-folder-id=standard-images,image-family=ubuntu-2204-lts,size=30GB \
  --network-interface subnet-id=$SUBNET_ID,nat-ip-version=ipv4 \
  --metadata ssh-keys="ubuntu:${YC_SSH_PUBLIC_KEY}" \
  --format json | grep -o '"id": *"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$VM_ID" ]; then
    echo "Failed to create VM"
    exit 1
fi

echo "VM created with ID: $VM_ID"

# Получаем IP адрес
sleep 10  # Ждем, пока VM получит IP
VM_IP=$(yc compute instance get $VM_ID \
  --folder-id $FOLDER_ID \
  --format json | grep -o '"one_to_one_nat": *{[^}]*"address": *"[^"]*"' | grep -o '"address": *"[^"]*"' | cut -d'"' -f4)

if [ -z "$VM_IP" ]; then
    echo "Failed to get VM IP"
    exit 1
fi

echo "VM public IP: $VM_IP"

# Ждем, пока VM полностью запустится
echo "Waiting for VM to initialize..."
sleep 30

# Создаем docker-compose.yml на лету
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  postgres:
    image: postgres:15
    container_name: postgres
    environment:
      POSTGRES_DB: project-sem-1
      POSTGRES_USER: validator
      POSTGRES_PASSWORD: val1dat0r
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U validator -d project-sem-1"]
      interval: 10s
      timeout: 5s
      retries: 5

  app:
    image: project-sem1:latest
    container_name: app
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "8080:8080"
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_DB: project-sem-1
      POSTGRES_USER: validator
      POSTGRES_PASSWORD: val1dat0r
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  postgres_data:
EOF

# Копируем файлы на сервер
echo "Copying files to server..."
scp -o StrictHostKeyChecking=no -o ConnectTimeout=30 \
  -i "$SSH_KEY_FILE" \
  Dockerfile \
  go.mod \
  go.sum \
  main.go \
  docker-compose.yml \
  ubuntu@$VM_IP:~/

# Копируем директории
for dir in handlers models utils db; do
    if [ -d "$dir" ]; then
        scp -o StrictHostKeyChecking=no -o ConnectTimeout=30 \
          -i "$SSH_KEY_FILE" \
          -r "$dir" \
          ubuntu@$VM_IP:~/
    fi
done

# Подключаемся к серверу и запускаем
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 \
  -i "$SSH_KEY_FILE" ubuntu@$VM_IP << 'EOF'
  echo "Setting up server..."
  
  # Установка Docker
  sudo apt-get update
  sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
  sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-compose
  
  # Добавление пользователя в группу docker
  sudo usermod -aG docker $USER
  
  # Сборка и запуск
  cd ~
  sudo docker-compose build
  sudo docker-compose up -d
  
  # Проверка
  echo "Waiting for services to start..."
  sleep 15
  
  echo "=== Service Status ==="
  sudo docker-compose ps
  
  echo "=== Testing API ==="
  curl -f http://localhost:8080/api/v0/prices || echo "API not ready yet"
  
  echo "=== Deployment logs ==="
  sudo docker-compose logs --tail=50
EOF

echo "=== Deployment Complete ==="
echo "Server IP: $VM_IP"
echo "API available at: http://$VM_IP:8080"
echo "SSH: ssh -i ~/.ssh/yc-key ubuntu@$VM_IP"

# Сохраняем IP для тестов
echo "$VM_IP" > vm_ip.txt

# Очистка
rm -f "$SSH_KEY_FILE"