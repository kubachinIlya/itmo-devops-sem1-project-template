#!/bin/bash
set -e

echo "=== Запуск в Yandex Cloud (сложный уровень) ==="

# Проверка наличия yc CLI
if ! command -v yc &> /dev/null; then
    echo "Установка Yandex Cloud CLI..."
    curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash
    export PATH="$PATH:/home/runner/yandex-cloud/bin"
    source /home/runner/.bashrc
fi

# Сохраняем SSH ключи
mkdir -p ~/.ssh
echo "$YC_SSH_PRIVATE_KEY" > ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa
echo "$YC_SSH_PUBLIC_KEY" > ~/.ssh/id_rsa.pub
chmod 644 ~/.ssh/id_rsa.pub

# Конфигурация из GitHub Secrets
YC_SERVICE_ACCOUNT_KEY_FILE="/tmp/sa-key.json"
echo "$YC_SA_KEY" > $YC_SERVICE_ACCOUNT_KEY_FILE

# Инициализация yc
yc config set service-account-key $YC_SERVICE_ACCOUNT_KEY_FILE
yc config set folder-id $YC_FOLDER_ID

# Параметры VM
VM_NAME="devops-vm-$(date +%s)"
SUBNET_ID="$YC_SUBNET_ID"
ZONE="ru-central1-a"

# Создание виртуальной машины
echo "Создание виртуальной машины $VM_NAME..."

# Создаем VM с Ubuntu 22.04
VM_ID=$(yc compute instance create \
    --name $VM_NAME \
    --zone $ZONE \
    --platform standard-v3 \
    --cores 2 \
    --memory 4GB \
    --core-fraction 100 \
    --create-boot-disk name=devops-boot,size=30GB,image-family=ubuntu-2204-lts,image-folder-id=standard-images \
    --preemptible \
    --network-interface subnet-id=$SUBNET_ID,nat-ip-version=ipv4 \
    --ssh-key ~/.ssh/id_rsa.pub \
    --metadata docker-install=true \
    --format json | jq -r '.id')

# Получение IP адреса
echo "Ожидание назначения IP адреса..."
sleep 10
VM_IP=$(yc compute instance get $VM_NAME --format json | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')
echo "✅ Сервер создан. IP адрес: $VM_IP"

# Сохраняем IP для следующих шагов
echo $VM_IP > vm_ip.txt
echo "IP адрес сохранен в vm_ip.txt: $VM_IP"

# Также сохраняем как переменную окружения для текущего шага
echo "VM_IP_ADDRESS=$VM_IP" >> $GITHUB_ENV

# Ожидание полной готовности VM
echo "Ожидание готовности VM (60 секунд)..."
sleep 60

# Копирование проекта на сервер
echo "Копирование файлов проекта на сервер..."
scp -o StrictHostKeyChecking=no -o ConnectTimeout=30 \
    -i ~/.ssh/id_rsa \
    -r \
    $(pwd) \
    ubuntu@$VM_IP:/home/ubuntu/app/

# Настройка сервера
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa ubuntu@$VM_IP << 'EOF'
    set -e
    
    echo "Настройка сервера..."
    
    # Установка Docker если не установлен
    if ! command -v docker &> /dev/null; then
        echo "Установка Docker..."
        sudo apt-get update
        sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
        sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi
    
    # Добавление пользователя в группу docker
    sudo usermod -aG docker $USER
    
    # Установка PostgreSQL клиента для тестов
    sudo apt-get install -y postgresql-client
    
    # Создание сети для Docker
    sudo docker network create app-network 2>/dev/null || true
EOF

# Запуск PostgreSQL в контейнере
echo "Запуск PostgreSQL..."
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa ubuntu@$VM_IP << 'EOF'
    cd /home/ubuntu/app
    
    # Запуск PostgreSQL
    sudo docker run -d \
        --name postgres-db \
        --network app-network \
        -e POSTGRES_DB=project-sem-1 \
        -e POSTGRES_USER=validator \
        -e POSTGRES_PASSWORD=val1dat0r \
        -p 5432:5432 \
        -v postgres_data:/var/lib/postgresql/data \
        --restart unless-stopped \
        postgres:15
    
    # Ожидание запуска PostgreSQL
    echo "Ожидание запуска PostgreSQL..."
    sleep 15
    
    # Проверка PostgreSQL
    sudo docker exec postgres-db pg_isready -U validator || true
EOF

# Сборка и запуск приложения
echo "Сборка и запуск приложения..."
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa ubuntu@$VM_IP << 'EOF'
    cd /home/ubuntu/app
    
    # Сборка Docker образа
    echo "Сборка Docker образа приложения..."
    sudo docker build -t devops-app:latest .
    
    # Запуск приложения
    sudo docker stop devops-app 2>/dev/null || true
    sudo docker rm devops-app 2>/dev/null || true
    
    sudo docker run -d \
        --name devops-app \
        --network app-network \
        -p 8080:8080 \
        -e POSTGRES_HOST=postgres-db \
        -e POSTGRES_PORT=5432 \
        -e POSTGRES_DB=project-sem-1 \
        -e POSTGRES_USER=validator \
        -e POSTGRES_PASSWORD=val1dat0r \
        --restart unless-stopped \
        devops-app:latest
    
    # Проверка запуска
    echo "Проверка запуска приложения..."
    sleep 10
    
    # Проверка что приложение отвечает
    echo "Проверка API..."
    curl -s http://localhost:8080/api/v0/prices || echo "API еще не готов"
    
    sudo docker logs devops-app --tail 20
    sudo docker ps | grep devops-app
EOF

# Проверка работоспособности удаленного API
echo "Проверка работоспособности API на удаленном сервере..."
for i in {1..30}; do
    echo "Попытка $i/30..."
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://$VM_IP:8080/api/v0/prices || echo "000")
    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "404" ]; then
        echo "✅ API на $VM_IP отвечает (код $HTTP_STATUS)"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "⚠️ API на $VM_IP не отвечает после 30 попыток"
    fi
    sleep 5
done

# Вывод информации
echo ""
echo "========================================="
echo "✅ Развертывание успешно завершено!"
echo "========================================="
echo "IP адрес сервера: $VM_IP"
echo "Приложение: http://$VM_IP:8080"
echo "PostgreSQL: $VM_IP:5432"
echo ""
echo "IP сохранен в:"
echo "  - vm_ip.txt"
echo "  - GITHUB_ENV как VM_IP_ADDRESS"
echo "========================================="

# Очистка
rm -f $YC_SERVICE_ACCOUNT_KEY_FILE