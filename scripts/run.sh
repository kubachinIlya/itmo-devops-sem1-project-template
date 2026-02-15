#!/bin/bash
set -e

echo "=== Deploying to Yandex Cloud (Complex Level) ==="

# Установка yc CLI, если его нет
if ! command -v yc &> /dev/null; then
    echo "Installing yc CLI..."
    
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash
    elif [ "$ARCH" = "aarch64" ]; then
        curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install_arm64.sh | bash
    else
        echo "Unsupported architecture: $ARCH"
        exit 1
    fi
    
    export PATH="$HOME/yandex-cloud/bin:$PATH"
    echo "yc CLI installed and added to PATH"
fi

# Проверяем, что yc доступен
if ! command -v yc &> /dev/null; then
    echo "yc CLI not found"
    exit 1
fi

echo "yc CLI version: $(yc --version | head -1)"

# Используем секреты из окружения
FOLDER_ID="$YC_FOLDER_ID"
SUBNET_ID="$YC_SUBNET_ID"
VM_NAME="project-sem1-vm"
VM_ZONE="ru-central1-a"

# Создаем временный файл для SSH ключа
echo "$YC_SSH_PRIVATE_KEY" > /tmp/yc-key
chmod 600 /tmp/yc-key

# Создаем временный файл для публичного ключа
echo "$YC_SSH_PUBLIC_KEY" > /tmp/yc-key.pub
chmod 644 /tmp/yc-key.pub

# Аутентификация через сервисный аккаунт
# Создаем временный файл с ключом сервисного аккаунта
cat > /tmp/sa-key.json << 'EOF'
{
  "id": "ajegv6p9s8h3d4b2f1k5",
  "service_account_id": "ajegv6p9s8h3d4b2f1k5",
  "created_at": "2024-01-01T00:00:00Z",
  "key_algorithm": "RSA_2048",
  "public_key": "-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----\n",
  "private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
}
EOF

# Настраиваем аутентификацию через сервисный аккаунт
yc config set service-account-key /tmp/sa-key.json
yc config set folder-id "$FOLDER_ID"
yc config set compute-default-zone "$VM_ZONE"

# Проверяем аутентификацию
echo "Checking authentication..."
if ! yc compute instance list --format json &>/dev/null; then
    echo "Authentication failed. Please check your service account key."
    exit 1
fi

echo "Authentication successful"

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

# Очистка временных файлов  bite
rm -f /tmp/yc-key /tmp/yc-key.pub

echo "=== Deployment Complete ==="
echo "Server IP: $VM_IP"
echo "API available at: http://$VM_IP:8080"

# Сохраняем IP для тестов
echo "$VM_IP" > vm_ip.txt