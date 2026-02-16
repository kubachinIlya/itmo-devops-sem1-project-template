#!/bin/bash
set -e

# Конфигурация
YC_ZONE="ru-central1-a"
SSH_USER="ubuntu"
INSTANCE_NAME="devops-vm-$(date +%s)"
YC_IMAGE_ID="fd8bnguet48kpk4ovt1u"
DEFAULT_SG_ID="enpt8kc9c5015ktou1kj"

# Функция для ключевых сообщений (только важное)
msg() {
    echo "✅ $1"
}

error() {
    echo "❌ $1" >&2
    exit 1
}

# Проверка и установка yc CLI
if ! command -v yc &> /dev/null; then
    curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash
    export PATH="$PATH:/home/runner/yandex-cloud/bin"
    source /home/runner/.bashrc
fi

# Настройка SSH
mkdir -p ~/.ssh
chmod 700 ~/.ssh
echo "$YC_SSH_PRIVATE_KEY" | sed 's/\r$//' > ~/.ssh/id_ed25519
echo "$YC_SSH_PUBLIC_KEY" | sed 's/\r$//' > ~/.ssh/id_ed25519.pub
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub

cat > ~/.ssh/config << EOF
Host *
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

# Настройка Yandex Cloud
YC_SA_KEY_FILE="/tmp/yc-sa-key.json"
echo "$YC_SA_KEY" > $YC_SA_KEY_FILE
yc config set service-account-key $YC_SA_KEY_FILE
yc config set folder-id $YC_FOLDER_ID

# Удаление старых VM
for OLD_VM in $(yc compute instance list --format json | jq -r '.[].name' | grep "devops-vm-" || echo ""); do
    yc compute instance delete $OLD_VM
    sleep 2
done

# Cloud-init конфиг
cat > cloud-init.yaml << EOF
#cloud-config
users:
  - name: $SSH_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat ~/.ssh/id_ed25519.pub)
EOF

# Создание VM
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
    --format json 2>/dev/null)

YC_INSTANCE_ID=$(echo "$CREATE_OUTPUT" | jq -r '.id')
[ -z "$YC_INSTANCE_ID" ] || [ "$YC_INSTANCE_ID" = "null" ] && error "Не удалось создать VM"

# Получение IP
for i in {1..10}; do
    PUBLIC_IP=$(yc compute instance get --id "$YC_INSTANCE_ID" --format json | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')
    [ ! -z "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "null" ] && break
    sleep 2
done

[ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "null" ] && error "Не удалось получить IP адрес"

echo $PUBLIC_IP > vm_ip.txt
echo "VM_IP_ADDRESS=$PUBLIC_IP" >> $GITHUB_ENV
msg "Создана VM с IP: $PUBLIC_IP"

# Ожидание SSH
for i in {1..10}; do
    if ssh -o ConnectTimeout=10 "$SSH_USER@$PUBLIC_IP" "echo ok" >/dev/null 2>&1; then
        break
    fi
    [ $i -eq 10 ] && error "SSH не доступен после 10 попыток"
    sleep 5
done

# Очистка временных файлов
rm -f cloud-init.yaml $YC_SA_KEY_FILE

# Установка Docker
ssh "$SSH_USER@$PUBLIC_IP" << 'EOF' > /dev/null 2>&1
    sudo apt update
    sudo apt install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo usermod -aG docker $USER
    sudo systemctl enable docker
    sudo systemctl start docker
EOF

# Копирование файлов
ssh "$SSH_USER@$PUBLIC_IP" "mkdir -p /home/$SSH_USER/app"
scp -r -o ConnectTimeout=30 $(pwd)/* "$SSH_USER@$PUBLIC_IP:/home/$SSH_USER/app/"

# Деплой
ssh "$SSH_USER@$PUBLIC_IP" << 'EOF'
    cd /home/ubuntu/app
    
    # Переименовываем dockerfile если нужно
    [ -f dockerfile ] && [ ! -f Dockerfile ] && mv dockerfile Dockerfile
    
    # Сборка образа
    sudo docker build -t devops-app:latest .
    
    # Создание сети
    sudo docker network create app-network 2>/dev/null || true
    
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
    
    sleep 10
    
    # Запуск приложения
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
EOF

# Проверка API
for i in {1..10}; do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://$PUBLIC_IP:8080/api/v0/prices || echo "000")
    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "404" ]; then
        msg "API доступен (HTTP $HTTP_STATUS)"
        break
    fi
    [ $i -eq 10 ] && error "API не отвечает после 10 попыток"
    sleep 5
done

msg "Развертывание завершено. IP: $PUBLIC_IP"