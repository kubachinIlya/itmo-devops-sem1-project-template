 #!/bin/bash
set -e

echo "=== Запуск в Yandex Cloud (сложный уровень) ==="

# Функция для логирования
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Проверка наличия yc CLI
if ! command -v yc &> /dev/null; then
    log "Установка Yandex Cloud CLI..."
    curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash
    export PATH="$PATH:/home/runner/yandex-cloud/bin"
    source /home/runner/.bashrc
fi

# Настройка SSH
log "Настройка SSH ключей..."
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
eval "$(ssh-agent -s)" > /dev/null
ssh-add ~/.ssh/id_rsa

# Конфигурация из GitHub Secrets
YC_SERVICE_ACCOUNT_KEY_FILE="/tmp/sa-key.json"
echo "$YC_SA_KEY" > $YC_SERVICE_ACCOUNT_KEY_FILE

# Инициализация yc
yc config set service-account-key $YC_SERVICE_ACCOUNT_KEY_FILE
yc config set folder-id $YC_FOLDER_ID

# Получаем ID сети по подсети
log "Получение информации о сети..."
NETWORK_ID=$(yc vpc subnet get $YC_SUBNET_ID --format json | jq -r '.network_id')
log "Network ID: $NETWORK_ID"

# Создаем группу безопасности для SSH и приложения
SG_NAME="devops-sg-$(date +%s | md5sum | head -c 8)"
log "Создание группы безопасности $SG_NAME..."

# Создаем группу безопасности
SG_ID=$(yc vpc security-group create \
    --name $SG_NAME \
    --network-id $NETWORK_ID \
    --rule direction=ingress,port=22,protocol=tcp,v4-cidrs=[0.0.0.0/0] \
    --rule direction=ingress,port=8080,protocol=tcp,v4-cidrs=[0.0.0.0/0] \
    --rule direction=ingress,port=5432,protocol=tcp,v4-cidrs=[0.0.0.0/0] \
    --rule direction=egress,port=any,protocol=any,v4-cidrs=[0.0.0.0/0] \
    --format json | jq -r '.id')

log "✅ Группа безопасности создана с ID: $SG_ID"

# Генерируем уникальный суффикс для ресурсов
UNIQUE_SUFFIX=$(date +%s | md5sum | head -c 8)
VM_NAME="devops-vm-${UNIQUE_SUFFIX}"
DISK_NAME="devops-boot-${UNIQUE_SUFFIX}"
ZONE="ru-central1-a"

log "Создание ресурсов с уникальными именами:"
log "  VM: $VM_NAME"
log "  Disk: $DISK_NAME"

# Создаем временный файл с публичным ключом
SSH_KEY_FILE="/tmp/ssh_key_${UNIQUE_SUFFIX}.pub"
echo "$YC_SSH_PUBLIC_KEY" | sed 's/\r$//' > $SSH_KEY_FILE
chmod 644 $SSH_KEY_FILE

# Удаляем старые VM если есть
log "Проверка и удаление старых VM..."
OLD_VMS=$(yc compute instance list --format json | jq -r '.[] | select(.name | startswith("devops-vm-")) | .name' 2>/dev/null || echo "")
if [ ! -z "$OLD_VMS" ]; then
    for OLD_VM in $OLD_VMS; do
        log "Удаляем старую VM: $OLD_VM"
        yc compute instance delete $OLD_VM --async > /dev/null 2>&1
    done
fi

# Создание виртуальной машины с группой безопасности
log "Создание виртуальной машины $VM_NAME..."

VM_ID=$(yc compute instance create \
    --name $VM_NAME \
    --zone $ZONE \
    --platform standard-v3 \
    --cores 2 \
    --memory 4GB \
    --core-fraction 100 \
    --create-boot-disk name=$DISK_NAME,size=30GB,image-family=ubuntu-2204-lts,image-folder-id=standard-images \
    --preemptible \
    --network-interface subnet-id=$YC_SUBNET_ID,security-group-id=$SG_ID,nat-ip-version=ipv4 \
    --ssh-key $SSH_KEY_FILE \
    --metadata serial-port-enable=1 \
    --format json | jq -r '.id' 2>/dev/null || echo "")

if [ -z "$VM_ID" ] || [ "$VM_ID" == "null" ]; then
    log "❌ Не удалось получить ID созданной VM"
    log "Пробуем найти VM по имени..."
    
    VM_ID=$(yc compute instance list --format json | jq -r ".[] | select(.name==\"$VM_NAME\") | .id" 2>/dev/null || echo "")
    
    if [ -z "$VM_ID" ] || [ "$VM_ID" == "null" ]; then
        log "❌ VM не найдена даже по имени"
        rm -f $SSH_KEY_FILE
        exit 1
    else
        log "✅ VM найдена по имени с ID: $VM_ID"
    fi
else
    log "✅ VM создана с ID: $VM_ID"
fi

# Получение IP адреса
log "Ожидание назначения IP адреса..."
for i in {1..30}; do
    VM_IP=$(yc compute instance get $VM_ID --format json 2>/dev/null | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')
    if [ ! -z "$VM_IP" ] && [ "$VM_IP" != "null" ]; then
        log "✅ IP адрес получен: $VM_IP"
        break
    fi
    log "Попытка $i/30..."
    sleep 2
done

if [ -z "$VM_IP" ] || [ "$VM_IP" == "null" ]; then
    log "❌ Не удалось получить IP адрес"
    rm -f $SSH_KEY_FILE
    exit 1
fi

# Сохраняем IP для следующих шагов
echo $VM_IP > vm_ip.txt
log "IP адрес сохранен в vm_ip.txt: $VM_IP"
echo "VM_IP_ADDRESS=$VM_IP" >> $GITHUB_ENV

# Очищаем временный файл с ключом
rm -f $SSH_KEY_FILE

# Проверка доступности SSH с увеличенным таймаутом
log "Ожидание готовности SSH на сервере (с увеличенным таймаутом)..."
for i in {1..30}; do
    log "Попытка $i/30... (прошло $((i*10)) секунд)"
    if nc -zv $VM_IP 22 2>/dev/null; then
        log "✅ Порт 22 открыт!"
        if ssh -o ConnectTimeout=10 -o BatchMode=yes ubuntu@$VM_IP "echo OK" 2>/dev/null; then
            log "✅ SSH доступен после $i попыток"
            break
        fi
    fi
    sleep 10
    if [ $i -eq 30 ]; then
        log "❌ SSH не доступен после 30 попыток"
        log "Проверка доступности портов..."
        
        # Проверка портов
        nc -zv $VM_IP 22 || log "Порт 22 закрыт"
        nc -zv $VM_IP 8080 || log "Порт 8080 закрыт"
        nc -zv $VM_IP 5432 || log "Порт 5432 закрыт"
        
        # Проверка группы безопасности
        log "Проверка группы безопасности $SG_NAME:"
        yc vpc security-group get $SG_NAME --format json | jq '.rules'
        
        exit 1
    fi
done
 

# Копирование проекта на сервер
log "Копирование файлов проекта на сервер..."
scp -r \
    -o ConnectTimeout=30 \
    -o StrictHostKeyChecking=no \
    -i ~/.ssh/id_rsa \
    $(pwd) \
    ubuntu@$VM_IP:/home/ubuntu/app/

# Настройка сервера
log "Настройка сервера..."
ssh -i ~/.ssh/id_rsa ubuntu@$VM_IP << 'EOF'
    set -e
    
    echo "Настройка сервера..."
    
    # Обновление пакетов
    sudo apt-get update > /dev/null 2>&1
    
    # Установка Docker если не установлен
    if ! command -v docker &> /dev/null; then
        echo "Установка Docker..."
        sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common > /dev/null 2>&1
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add - > /dev/null 2>&1
        sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /dev/null 2>&1
        sudo apt-get update > /dev/null 2>&1
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null 2>&1
    fi
    
    # Добавление пользователя в группу docker
    sudo usermod -aG docker $USER
    
    # Установка PostgreSQL клиента
    sudo apt-get install -y postgresql-client > /dev/null 2>&1
    
    # Создание сети для Docker
    sudo docker network create app-network 2>/dev/null || true
    
    echo "Настройка сервера завершена"
EOF

# Запуск PostgreSQL в контейнере
log "Запуск PostgreSQL..."
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
        postgres:15 > /dev/null 2>&1
    
    # Ожидание запуска PostgreSQL
    echo "Ожидание запуска PostgreSQL..."
    sleep 15
    
    # Проверка PostgreSQL
    sudo docker exec postgres-db pg_isready -U validator || true
EOF

# Сборка и запуск приложения
log "Сборка и запуск приложения..."
ssh -i ~/.ssh/id_rsa ubuntu@$VM_IP << 'EOF'
    cd /home/ubuntu/app
    
    # Сборка Docker образа
    echo "Сборка Docker образа приложения..."
    sudo docker build -t devops-app:latest . > /dev/null 2>&1
    
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
        devops-app:latest > /dev/null 2>&1
    
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
log "Проверка работоспособности API на удаленном сервере..."
for i in {1..30}; do
    log "Попытка $i/30..."
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://$VM_IP:8080/api/v0/prices || echo "000")
    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "404" ]; then
        log "✅ API на $VM_IP отвечает (код $HTTP_STATUS)"
        break
    fi
    if [ $i -eq 30 ]; then
        log "⚠️ API на $VM_IP не отвечает после 30 попыток"
    fi
    sleep 5
done

# Вывод информации
log ""
log "========================================="
log "✅ Развертывание успешно завершено!"
log "========================================="
log "IP адрес сервера: $VM_IP"
log "Приложение: http://$VM_IP:8080"
log "PostgreSQL: $VM_IP:5432"
log ""
log "IP сохранен в:"
log "  - vm_ip.txt"
log "  - GITHUB_ENV как VM_IP_ADDRESS"
log "========================================="

# Очистка
rm -f $YC_SERVICE_ACCOUNT_KEY_FILE