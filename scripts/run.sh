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

# Настройка SSH ключей из GitHub Secrets
log "Настройка SSH ключей..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Сохраняем ключи
echo "$YC_SSH_PRIVATE_KEY" > ~/.ssh/id_ed25519
echo "$YC_SSH_PUBLIC_KEY" > ~/.ssh/id_ed25519.pub
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
yc config set token $YC_SA_KEY
yc config set folder-id $YC_FOLDER_ID

# Параметры
YC_ZONE="ru-central1-a"
SSH_USER="ubuntu"
INSTANCE_NAME="devops-vm-$(date +%s)"
YC_IMAGE_ID="fd8bnguet48kpk4ovt1u" # Ubuntu 22.04 LTS

log "Создание VM: $INSTANCE_NAME"

# Создаем cloud-init конфиг для правильной настройки пользователя
cat > cloud-init.yaml << EOF
#cloud-config
users:
  - name: $SSH_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - $(echo "$YC_SSH_PUBLIC_KEY")
ssh_pwauth: no
disable_root: true
EOF

# Удаляем старые VM
log "Очистка старых VM..."
OLD_VMS=$(yc compute instance list --format json | jq -r '.[] | select(.name | startswith("devops-vm-")) | .name' 2>/dev/null || echo "")
if [ ! -z "$OLD_VMS" ]; then
    for OLD_VM in $OLD_VMS; do
        log "Удаляем старую VM: $OLD_VM"
        yc compute instance delete $OLD_VM --async > /dev/null 2>&1
    done
fi

# Создание виртуальной машины
log "Создание виртуальной машины..."

YC_INSTANCE_ID=$(yc compute instance create \
    --name "$INSTANCE_NAME" \
    --folder-id "$YC_FOLDER_ID" \
    --zone "$YC_ZONE" \
    --network-interface subnet-name=default-$YC_ZONE,nat-ip-version=ipv4 \
    --create-boot-disk size=30,image-id="$YC_IMAGE_ID" \
    --memory=4 \
    --cores=2 \
    --platform standard-v3 \
    --preemptible \
    --metadata-from-file user-data=cloud-init.yaml \
    --format json | jq -r '.id')

if [ -z "$YC_INSTANCE_ID" ] || [ "$YC_INSTANCE_ID" == "null" ]; then
    log "❌ Ошибка создания VM"
    exit 1
fi

log "✅ Instance ID: $YC_INSTANCE_ID"

# Получение публичного IP
log "Получение IP адреса..."
for i in {1..30}; do
    PUBLIC_IP=$(yc compute instance get --id "$YC_INSTANCE_ID" --format json | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')
    if [ ! -z "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "null" ]; then
        log "✅ Public IP: $PUBLIC_IP"
        break
    fi
    log "Попытка $i/30..."
    sleep 2
done

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" == "null" ]; then
    log "❌ Не удалось получить IP адрес"
    exit 1
fi

# Сохраняем IP
echo $PUBLIC_IP > vm_ip.txt
echo "VM_IP_ADDRESS=$PUBLIC_IP" >> $GITHUB_ENV
log "IP сохранен в vm_ip.txt: $PUBLIC_IP"

# Ожидание SSH
log "Ожидание SSH..."
for i in {1..30}; do
    log "Попытка $i/30..."
    if ssh -o ConnectTimeout=10 "$SSH_USER@$PUBLIC_IP" "echo ok" >/dev/null 2>&1; then
        log "✅ SSH доступен"
        break
    fi
    sleep 10
    if [ $i -eq 30 ]; then
        log "❌ SSH не доступен после 30 попыток"
        exit 1
    fi
done

# Установка Docker
log "Установка Docker..."
ssh "$SSH_USER@$PUBLIC_IP" <<'EOF'
    # Удаление старых версий
    sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Установка зависимостей
    sudo apt update
    sudo apt install -y ca-certificates curl software-properties-common
    
    # Добавление Docker репозитория
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Установка Docker
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin postgresql-client
    
    # Добавление пользователя в группу docker
    sudo usermod -aG docker $USER
    
    # Включение Docker
    sudo systemctl enable docker
    sudo systemctl start docker
EOF

# Копирование файлов проекта
log "Копирование файлов проекта..."
scp -r \
    -o ConnectTimeout=30 \
    $(pwd) \
    "$SSH_USER@$PUBLIC_IP:/home/$SSH_USER/app/"

# Запуск PostgreSQL
log "Запуск PostgreSQL..."
ssh "$SSH_USER@$PUBLIC_IP" << 'EOF'
    cd /home/ubuntu/app
    
    # Запуск PostgreSQL контейнера
    sudo docker run -d \
        --name postgres-db \
        -e POSTGRES_DB=project-sem-1 \
        -e POSTGRES_USER=validator \
        -e POSTGRES_PASSWORD=val1dat0r \
        -p 5432:5432 \
        -v postgres_data:/var/lib/postgresql/data \
        --restart unless-stopped \
        postgres:15
    
    # Ожидание PostgreSQL
    echo "Ожидание PostgreSQL..."
    sleep 15
EOF

# Сборка и запуск приложения
log "Сборка и запуск приложения..."
ssh "$SSH_USER@$PUBLIC_IP" << 'EOF'
    cd /home/ubuntu/app
    
    # Сборка Docker образа
    sudo docker build -t devops-app:latest .
    
    # Запуск приложения
    sudo docker stop devops-app 2>/dev/null || true
    sudo docker rm devops-app 2>/dev/null || true
    
    sudo docker run -d \
        --name devops-app \
        -p 8080:8080 \
        -e POSTGRES_HOST=localhost \
        -e POSTGRES_PORT=5432 \
        -e POSTGRES_DB=project-sem-1 \
        -e POSTGRES_USER=validator \
        -e POSTGRES_PASSWORD=val1dat0r \
        --restart unless-stopped \
        devops-app:latest
    
    # Проверка
    sleep 10
    sudo docker ps | grep devops-app
EOF

# Проверка API
log "Проверка API..."
for i in {1..30}; do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://$PUBLIC_IP:8080/api/v0/prices || echo "000")
    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "404" ]; then
        log "✅ API доступен (код $HTTP_STATUS)"
        break
    fi
    log "Ожидание API... $i/30"
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

# Очистка
rm -f cloud-init.yaml