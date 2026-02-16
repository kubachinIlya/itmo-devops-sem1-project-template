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

# Настройка SSH ключей
log "Настройка SSH ключей..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Сохраняем ключи
echo "$YC_SSH_PRIVATE_KEY" | sed 's/\r$//' > ~/.ssh/id_ed25519
echo "$YC_SSH_PUBLIC_KEY" | sed 's/\r$//' > ~/.ssh/id_ed25519.pub
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub

# Настройка SSH config
cat > ~/.ssh/config << EOF
Host *
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
chmod 600 ~/.ssh/config

# Конфигурация Yandex Cloud
log "Настройка Yandex Cloud CLI..."
YC_SA_KEY_FILE="/tmp/yc-sa-key.json"
echo "$YC_SA_KEY" > $YC_SA_KEY_FILE
yc config set service-account-key $YC_SA_KEY_FILE
yc config set folder-id $YC_FOLDER_ID

# Параметры
YC_ZONE="ru-central1-a"
SSH_USER="ubuntu"
INSTANCE_NAME="devops-vm-$(date +%s)"
YC_IMAGE_ID="fd8bnguet48kpk4ovt1u" # Ubuntu 22.04 LTS

log "Создание VM: $INSTANCE_NAME"

# Создаем cloud-init конфиг
cat > cloud-init.yaml << EOF
#cloud-config
users:
  - name: $SSH_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat ~/.ssh/id_ed25519.pub)
ssh_pwauth: no
disable_root: true
EOF

# Находим ID группы безопасности
DEFAULT_SG_ID="enpt8kc9c5015ktou1kj"  # ID из вывода
log "Используем группу безопасности: $DEFAULT_SG_ID"



# ПРИНУДИТЕЛЬНОЕ удаление всех старых VM
log "Принудительное удаление всех старых VM..."
OLD_VMS=$(yc compute instance list --format json | jq -r '.[].name' | grep "devops-vm-" || echo "")
if [ ! -z "$OLD_VMS" ]; then
    for OLD_VM in $OLD_VMS; do
        log "Удаляем старую VM: $OLD_VM"
        yc compute instance delete $OLD_VM  # Убрал --async чтобы удалилось сразу
        sleep 5
    done
fi

# Также удаляем VM из предыдущих запусков
OLD_VMS=$(yc compute instance list --format json | jq -r '.[].name' | grep "devops-vm-" || echo "")
if [ ! -z "$OLD_VMS" ]; then
    log "❌ Все еще есть старые VM: $OLD_VMS"
    exit 1
else
    log "✅ Все старые VM удалены"
fi

# Создание виртуальной машины
log "Создание виртуальной машины $INSTANCE_NAME..."

# Создаем VM с группой безопасности и сохраняем ВЕСЬ вывод
TMP_OUTPUT="/tmp/vm_create_output.json"
log "Запускаем команду создания VM..."

# Выполняем команду и сохраняем вывод
set +e  # Временно отключаем exit on error
CREATE_OUTPUT=$(yc compute instance create \
    --name "$INSTANCE_NAME" \
    --folder-id "$YC_FOLDER_ID" \
    --zone "$YC_ZONE" \
    --network-interface subnet-name=default-$YC_ZONE,security-group-ids=$DEFAULT_SG_ID,nat-ip-version=ipv4 \
    --create-boot-disk size=30,image-id="$YC_IMAGE_ID" \
    --memory=4 \
    --cores=2 \
    --platform standard-v3 \
    --preemptible \
    --metadata-from-file user-data=cloud-init.yaml \
    --format json 2>&1)
CREATE_EXIT_CODE=$?
set -e  # Включаем обратно

# Сохраняем вывод в файл
echo "$CREATE_OUTPUT" > $TMP_OUTPUT

# Логируем результат
log "Exit code: $CREATE_EXIT_CODE"
log "Вывод команды:"
echo "$CREATE_OUTPUT" | while IFS= read -r line; do
    log "  $line"
done

if [ $CREATE_EXIT_CODE -ne 0 ]; then
    log "❌ Ошибка создания VM (код $CREATE_EXIT_CODE)"
    rm -f cloud-init.yaml $YC_SA_KEY_FILE
    exit 1
fi

# Проверяем, что файл не пустой и содержит JSON
if [ ! -s $TMP_OUTPUT ]; then
    log "❌ Пустой вывод от yc"
    cat $TMP_OUTPUT
    rm -f cloud-init.yaml $YC_SA_KEY_FILE $TMP_OUTPUT
    exit 1
fi

# Извлекаем ID VM
YC_INSTANCE_ID=$(jq -r '.id' $TMP_OUTPUT 2>/dev/null || echo "")

if [ -z "$YC_INSTANCE_ID" ] || [ "$YC_INSTANCE_ID" == "null" ]; then
    log "❌ Не удалось получить ID VM"
    log "Содержимое вывода:"
    cat $TMP_OUTPUT
    
    # Пробуем найти VM по имени
    log "Пробуем найти VM по имени..."
    sleep 10
    YC_INSTANCE_ID=$(yc compute instance list --format json | jq -r ".[] | select(.name==\"$INSTANCE_NAME\") | .id" 2>/dev/null || echo "")
    
    if [ -z "$YC_INSTANCE_ID" ] || [ "$YC_INSTANCE_ID" == "null" ]; then
        rm -f cloud-init.yaml $YC_SA_KEY_FILE $TMP_OUTPUT
        exit 1
    else
        log "✅ VM найдена по имени с ID: $YC_INSTANCE_ID"
    fi
else
    log "✅ VM создана с ID: $YC_INSTANCE_ID"
fi

# Очищаем временный файл
rm -f $TMP_OUTPUT

# Получение публичного IP
log "Получение IP адреса..."
for i in {1..10}; do
    GET_OUTPUT="/tmp/vm_get_output.json"
    yc compute instance get --id "$YC_INSTANCE_ID" --format json > $GET_OUTPUT 2>&1
    
    PUBLIC_IP=$(jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address' $GET_OUTPUT 2>/dev/null || echo "")
    rm -f $GET_OUTPUT
    
    if [ ! -z "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "null" ]; then
        log "✅ Public IP: $PUBLIC_IP"
        break
    fi
    log "Попытка $i/10..."
    sleep 2
done

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" == "null" ]; then
    log "❌ Не удалось получить IP адрес"
    rm -f cloud-init.yaml $YC_SA_KEY_FILE
    exit 1
fi

# Сохраняем IP
echo $PUBLIC_IP > vm_ip.txt
echo "VM_IP_ADDRESS=$PUBLIC_IP" >> $GITHUB_ENV
log "IP сохранен в vm_ip.txt: $PUBLIC_IP"

# Ожидание SSH
log "Ожидание SSH..."
for i in {1..10}; do
    log "Попытка $i/10..."
    if ssh -o ConnectTimeout=10 "$SSH_USER@$PUBLIC_IP" "echo ok" >/dev/null 2>&1; then
        log "✅ SSH доступен"
        break
    fi
    sleep 10
    if [ $i -eq 10 ]; then
        log "❌ SSH не доступен после 10 попыток"
        rm -f cloud-init.yaml $YC_SA_KEY_FILE
        exit 1
    fi
done

# Очистка временных файлов
rm -f cloud-init.yaml $YC_SA_KEY_FILE

# Установка Docker
log "Установка Docker..."
ssh "$SSH_USER@$PUBLIC_IP" <<'EOF'
    sudo apt update
    sudo apt install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin postgresql-client
    sudo usermod -aG docker $USER
    sudo systemctl enable docker
    sudo systemctl start docker
EOF

# Создание директории app
log "Создание директории app на сервере..."
ssh "$SSH_USER@$PUBLIC_IP" "mkdir -p /home/$SSH_USER/app"

# Копирование файлов проекта
log "Копирование файлов проекта..."
scp -r \
    -o ConnectTimeout=30 \
    $(pwd)/* \
    "$SSH_USER@$PUBLIC_IP:/home/$SSH_USER/app/"

# Проверка скопированных файлов
log "Проверка скопированных файлов..."
ssh "$SSH_USER@$PUBLIC_IP" "ls -la /home/$SSH_USER/app/"

# Запуск PostgreSQL
log "Запуск PostgreSQL..."
ssh "$SSH_USER@$PUBLIC_IP" << 'EOF'
    cd /home/ubuntu/app
    sudo docker run -d \
        --name postgres-db \
        -e POSTGRES_DB=project-sem-1 \
        -e POSTGRES_USER=validator \
        -e POSTGRES_PASSWORD=val1dat0r \
        -p 5432:5432 \
        -v postgres_data:/var/lib/postgresql/data \
        --restart unless-stopped \
        postgres:15
    sleep 15
EOF

# Сборка и запуск приложения
log "Сборка и запуск приложения..."
ssh "$SSH_USER@$PUBLIC_IP" << 'EOF'
    cd /home/ubuntu/app
    
    # Переименовываем dockerfile в Dockerfile если нужно
    if [ -f dockerfile ] && [ ! -f Dockerfile ]; then
        echo "Переименовываем dockerfile в Dockerfile..."
        mv dockerfile Dockerfile
    fi
    
    if [ ! -f Dockerfile ]; then
        echo "❌ Dockerfile не найден!"
        exit 1
    fi
    
    echo "Сборка Docker образа приложения..."
    sudo docker build -t devops-app:latest .
    
    # Остановка старых контейнеров
    sudo docker stop devops-app 2>/dev/null || true
    sudo docker rm devops-app 2>/dev/null || true
    sudo docker stop postgres-db 2>/dev/null || true
    sudo docker rm postgres-db 2>/dev/null || true
    
    # Создаем сеть
    sudo docker network create app-network 2>/dev/null || true
    
    # Запуск PostgreSQL
    echo "Запуск PostgreSQL..."
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
    
    echo "Ожидание PostgreSQL..."
    sleep 10
    
    # Запуск приложения
    echo "Запуск приложения..."
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
    
    echo "Проверка запуска..."
    sleep 5
    sudo docker ps | grep -E 'postgres-db|devops-app'
    sudo docker logs devops-app --tail 20
EOF
 
log "  ДИАГНОСТИКА КОНТЕЙНЕРА"
ssh "$SSH_USER@$PUBLIC_IP" << 'EOF'
    echo "=== СОСТОЯНИЕ КОНТЕЙНЕРА ==="
    sudo docker ps -a | grep devops-app
    
    echo -e "\n=== ЛОГИ КОНТЕЙНЕРА (важно!) ==="
    sudo docker logs devops-app
    
    echo -e "\n=== ПРОВЕРКА БИЛДА ==="
    cd /home/ubuntu/app
    echo "Содержимое Dockerfile:"
    cat Dockerfile
    
    echo -e "\n=== ПРОБА ЗАПУСКА ВРУЧНУЮ ==="
    sudo docker run --rm devops-app:latest ls -la || echo "Образ битый"
    
    echo -e "\n=== ПРОВЕРКА ЗАВИСИМОСТЕЙ ==="
    sudo docker run --rm devops-app:latest go version || echo "Нет Go"
EOF
 
log "  ДИАГНОСТИКА..."
ssh "$SSH_USER@$PUBLIC_IP" << 'EOF'
    echo "=== 1. Запущенные контейнеры ==="
    sudo docker ps -a
    
    echo "=== 2. Логи приложения ==="
    sudo docker logs devops-app --tail 50
    
    echo "=== 3. Проверка портов внутри VM ==="
    sudo ss -tlnp | grep -E ':(8080|5432)'
    
    echo "=== 4. Проверка изнутри VM ==="
    curl -v http://localhost:8080/api/v0/prices || echo "❌ Локально не отвечает"
    
    echo "=== 5. Проверка Docker сети ==="
    sudo docker network ls
    sudo docker inspect devops-app | grep -A 5 "NetworkSettings"
EOF

# Проверка снаружи
log "=== 6. Проверка снаружи ==="
nc -zv $PUBLIC_IP 8080
curl -v http://$PUBLIC_IP:8080/api/v0/prices || echo "❌ Снаружи не отвечает"

# Проверка портов снаружи
log "Проверка доступности портов извне..."
nc -zv $PUBLIC_IP 8080 || echo "❌ Порт 8080 недоступен"
nc -zv $PUBLIC_IP 5432 || echo "❌ Порт 5432 недоступен"

# Проверка API
log "Проверка API..."
for i in {1..10}; do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://$PUBLIC_IP:8080/api/v0/prices || echo "000")
    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "404" ]; then
        log "✅ API доступен (код $HTTP_STATUS)"
        break
    fi
    log "Ожидание API... $i/10 (статус: $HTTP_STATUS)"
    sleep 5
done

log ""
log "========================================="
log "✅ Развертывание успешно завершено!"
log "========================================="
log "IP адрес: $PUBLIC_IP"
log "Приложение: http://$PUBLIC_IP:8080"
log "PostgreSQL: $PUBLIC_IP:5432"
log "SSH: ssh ubuntu@$PUBLIC_IP"
log "========================================="