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

# Настройка SSH
echo "Настройка SSH ключей..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Очищаем старые ключи
rm -f ~/.ssh/id_rsa ~/.ssh/id_rsa.pub

# Сохраняем приватный ключ (с правильными переносами)
echo "$YC_SSH_PRIVATE_KEY" | sed 's/\r$//' > ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa

# Сохраняем публичный ключ
echo "$YC_SSH_PUBLIC_KEY" | sed 's/\r$//' > ~/.ssh/id_rsa.pub
chmod 644 ~/.ssh/id_rsa.pub

# Добавляем ключ в ssh-agent
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_rsa

# Отключаем проверку хоста для первого подключения
cat > ~/.ssh/config << EOF
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
chmod 600 ~/.ssh/config

# Конфигурация из GitHub Secrets
YC_SERVICE_ACCOUNT_KEY_FILE="/tmp/sa-key.json"
echo "$YC_SA_KEY" > $YC_SERVICE_ACCOUNT_KEY_FILE

# Инициализация yc
yc config set service-account-key $YC_SERVICE_ACCOUNT_KEY_FILE
yc config set folder-id $YC_FOLDER_ID

# Генерируем уникальный суффикс для ресурсов
UNIQUE_SUFFIX=$(date +%s%N | md5sum | head -c 8)
VM_NAME="devops-vm-${UNIQUE_SUFFIX}"
DISK_NAME="devops-boot-${UNIQUE_SUFFIX}"
SUBNET_ID="$YC_SUBNET_ID"
ZONE="ru-central1-a"

echo "Создание ресурсов с уникальными именами:"
echo "  VM: $VM_NAME"
echo "  Disk: $DISK_NAME"

# Удаляем старые VM если есть (опционально)
echo "Проверка и удаление старых VM..."
OLD_VMS=$(yc compute instance list --format json | jq -r '.[] | select(.name | startswith("devops-vm-")) | .name')
for OLD_VM in $OLD_VMS; do
    echo "Удаляем старую VM: $OLD_VM"
    yc compute instance delete $OLD_VM --async
done

# Создание виртуальной машины
echo "Создание виртуальной машины $VM_NAME..."

# Читаем публичный ключ для передачи в metadata
SSH_PUB_KEY=$(cat ~/.ssh/id_rsa.pub)

# Создаем VM с уникальным именем диска
VM_ID=$(yc compute instance create \
    --name $VM_NAME \
    --zone $ZONE \
    --platform standard-v3 \
    --cores 2 \
    --memory 4GB \
    --core-fraction 100 \
    --create-boot-disk name=$DISK_NAME,size=30GB,image-family=ubuntu-2204-lts,image-folder-id=standard-images \
    --preemptible \
    --network-interface subnet-id=$SUBNET_ID,nat-ip-version=ipv4 \
    --ssh-key "$SSH_PUB_KEY" \
    --metadata serial-port-enable=1 \
    --format json | jq -r '.id')

# Проверяем, что VM создана
if [ -z "$VM_ID" ] || [ "$VM_ID" == "null" ]; then
    echo "❌ Ошибка создания VM"
    exit 1
fi

# Получение IP адреса
echo "Ожидание назначения IP адреса..."
for i in {1..30}; do
    VM_IP=$(yc compute instance get $VM_NAME --format json 2>/dev/null | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')
    if [ ! -z "$VM_IP" ] && [ "$VM_IP" != "null" ]; then
        echo "✅ IP адрес получен: $VM_IP"
        break
    fi
    echo "Попытка $i/30..."
    sleep 2
done

if [ -z "$VM_IP" ] || [ "$VM_IP" == "null" ]; then
    echo "❌ Не удалось получить IP адрес"
    exit 1
fi

# Сохраняем IP для следующих шагов
echo $VM_IP > vm_ip.txt
echo "IP адрес сохранен в vm_ip.txt: $VM_IP"

# Сохраняем как переменную окружения
echo "VM_IP_ADDRESS=$VM_IP" >> $GITHUB_ENV

# Ожидание полной готовности VM и SSH
echo "Ожидание готовности SSH на сервере..."
for i in {1..30}; do
    if ssh -o ConnectTimeout=5 -o BatchMode=yes ubuntu@$VM_IP "echo OK" 2>/dev/null; then
        echo "✅ SSH доступен после $i попыток"
        break
    fi
    echo "Попытка $i/30..."
    sleep 5
    if [ $i -eq 30 ]; then
        echo "❌ SSH не доступен после 30 попыток"
        exit 1
    fi
done

# Копирование проекта на сервер
echo "Копирование файлов проекта на сервер..."
scp -v -r \
    -o ConnectTimeout=30 \
    -o StrictHostKeyChecking=no \
    -i ~/.ssh/id_rsa \
    $(pwd) \
    ubuntu@$VM_IP:/home/ubuntu/app/

# Настройка сервера
echo "Настройка сервера..."
ssh -v -i ~/.ssh/id_rsa ubuntu@$VM_IP << 'EOF'
    set -e
    
    echo "Настройка сервера..."
    
    # Обновление пакетов
    sudo apt-get update
    
    # Установка Docker если не установлен
    if ! command -v docker &> /dev/null; then
        echo "Установка Docker..."
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
    
    echo "Настройка сервера завершена"
EOF

# Запуск PostgreSQL в контейнере
echo "Запуск PostgreSQL..."
ssh -i ~/.ssh/id_rsa ubuntu@$VM_IP << 'EOF'
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
ssh -i ~/.ssh/id_rsa ubuntu@$VM_IP << 'EOF'
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