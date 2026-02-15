#!/bin/bash
set -e

echo "=== Deploying to Yandex Cloud (Complex Level) ==="

# Переменные из GitHub Secrets
YC_OAUTH_TOKEN="${YC_OAUTH_TOKEN}"
FOLDER_ID="${YC_FOLDER_ID}"
SUBNET_ID="${YC_SUBNET_ID}"
VM_NAME="project-sem1-vm"
VM_ZONE="ru-central1-a"

# Создаем временные файлы для SSH ключей
echo "${YC_SSH_PRIVATE_KEY}" > /tmp/yc-key
chmod 600 /tmp/yc-key
echo "${YC_SSH_PUBLIC_KEY}" > /tmp/yc-key.pub
chmod 644 /tmp/yc-key.pub

# Установка yc CLI
if ! command -v yc &> /dev/null; then
    echo "Installing yc CLI..."
    curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash
    
    # Добавляем yc в PATH для текущей сессии
    export PATH="$HOME/yandex-cloud/bin:$PATH"
    
    # Добавляем в bashrc для будущих сессий
    echo 'export PATH="$HOME/yandex-cloud/bin:$PATH"' >> ~/.bashrc
    
    echo "yc CLI installed"
fi

# Проверяем, что yc доступен
if ! command -v yc &> /dev/null; then
    echo "ERROR: yc command not found after installation"
    exit 1
fi

# Настройка через OAuth токен (ДЕЛАЕМ ЭТО ДО ЛЮБЫХ ДРУГИХ КОМАНД)
echo "Configuring yc with OAuth token..."
yc config set token "$YC_OAUTH_TOKEN"
yc config set folder-id "$FOLDER_ID"
yc config set compute-default-zone "$VM_ZONE"

# Проверяем, что токен работает
echo "Testing yc configuration..."
if ! yc config list &> /dev/null; then
    echo "ERROR: Failed to configure yc with token"
    exit 1
fi

# Проверяем доступ к Compute Cloud
echo "Checking Yandex Cloud Compute access..."
if ! yc compute instance list &> /dev/null; then
    echo "ERROR: Cannot access Compute Cloud. Check token permissions."
    exit 1
fi

echo "YC configuration successful!"

# Создаем виртуальную машину
echo "Creating VM in Yandex Cloud..."
echo "Folder ID: $FOLDER_ID"
echo "Subnet ID: $SUBNET_ID"
echo "Zone: $VM_ZONE"

VM_ID=$(yc compute instance create \
  --name $VM_NAME \
  --zone $VM_ZONE \
  --folder-id $FOLDER_ID \
  --platform standard-v3 \
  --cores 2 \
  --memory 4GB \
  --create-boot-disk image-folder-id=standard-images,image-family=ubuntu-2204-lts,size=30GB \
  --network-interface subnet-id=$SUBNET_ID,nat-ip-version=ipv4 \
  --metadata ssh-keys="ubuntu:$(cat /tmp/yc-key.pub)" \
  --format json | grep -o '"id": *"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$VM_ID" ]; then
    echo "Failed to create VM"
    exit 1
fi

echo "VM created with ID: $VM_ID"

# Получаем IP адрес
sleep 10
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

# Проверяем доступность SSH
echo "Checking SSH connection..."
for i in {1..30}; do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i /tmp/yc-key ubuntu@$VM_IP "echo OK" 2>/dev/null; then
        echo "SSH connection successful"
        break
    fi
    echo "Waiting for SSH... $i/30"
    sleep 5
done

# Создаем docker-compose.yml
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
scp -o StrictHostKeyChecking=no -i /tmp/yc-key \
  Dockerfile \
  go.mod \
  go.sum \
  main.go \
  docker-compose.yml \
  ubuntu@$VM_IP:~/

# Копируем директории
scp -o StrictHostKeyChecking=no -i /tmp/yc-key \
  -r handlers models utils db \
  ubuntu@$VM_IP:~/

# Подключаемся к серверу и запускаем
ssh -o StrictHostKeyChecking=no -i /tmp/yc-key ubuntu@$VM_IP << 'EOF'
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
EOF

# Очистка временных файлов
rm -f /tmp/yc-key /tmp/yc-key.pub

echo "=== Deployment Complete ==="
echo "Server IP: $VM_IP"
echo "API available at: http://$VM_IP:8080"

# Сохраняем IP для тестов
echo "$VM_IP" > vm_ip.txt