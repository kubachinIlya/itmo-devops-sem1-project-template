#!/bin/bash
set -e
set -o pipefail

echo "=== Deploying to Yandex Cloud (Complex Level) ==="

# Переменные из GitHub Secrets
YC_FOLDER_ID="${YC_FOLDER_ID}"
YC_ZONE="ru-central1-a"  # Фиксируем зону
YC_TOKEN="${YC_TOKEN}"
YC_IMAGE_ID="fd8bnguet48kpk4ovt1u"  # Ubuntu 22.04 LTS
INSTANCE_NAME="prices-app-$(date +%s)"
SSH_USER="ubuntu"
PUBLIC_KEY="${YC_SSH_PUBLIC_KEY}"
PRIVATE_KEY="${YC_SSH_PRIVATE_KEY}"
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"

echo "Setting up SSH keys..."
mkdir -p "$HOME/.ssh"
echo "$PUBLIC_KEY" >"$SSH_KEY_PATH.pub"
echo "$PRIVATE_KEY" >"$SSH_KEY_PATH"

# Создаем SSH config
cat > "$HOME/.ssh/config" <<EOF
Host *
    IdentityFile $SSH_KEY_PATH
    IdentitiesOnly yes
    StrictHostKeyChecking no
EOF

chmod 600 "$SSH_KEY_PATH"
chmod 644 "$SSH_KEY_PATH.pub"
chmod 600 "$HOME/.ssh/config"

# Создаем cloud-init конфиг
cat > cloud-init.yaml <<EOF
#cloud-config
users:
  - name: $SSH_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - $(echo "$PUBLIC_KEY")
ssh_pwauth: no
disable_root: true
EOF

# Настраиваем YC CLI
echo "Configuring Yandex Cloud CLI..."
yc config set token "$YC_TOKEN"

# Проверяем, что токен работает
echo "Checking YC authentication..."
if ! yc config list &>/dev/null; then
    echo "ERROR: Failed to authenticate with Yandex Cloud"
    exit 1
fi

# Создаем VM
echo "Creating VM in Yandex Cloud..."
YC_INSTANCE_ID=$(yc compute instance create \
    --name "$INSTANCE_NAME" \
    --folder-id "$YC_FOLDER_ID" \
    --zone "$YC_ZONE" \
    --network-interface subnet-name="default-$YC_ZONE",nat-ip-version=ipv4 \
    --create-boot-disk size=20,image-id="$YC_IMAGE_ID" \
    --memory=2 \
    --cores=2 \
    --metadata-from-file user-data=cloud-init.yaml \
    --format json | jq -r '.id')

if [ -z "$YC_INSTANCE_ID" ] || [ "$YC_INSTANCE_ID" = "null" ]; then
    echo "ERROR: Failed to create VM"
    exit 1
fi

echo "Instance ID: $YC_INSTANCE_ID"

# Получаем публичный IP
echo "Getting public IP..."
PUBLIC_IP=$(yc compute instance get --id "$YC_INSTANCE_ID" --format json | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "null" ]; then
    echo "ERROR: Failed to get public IP"
    exit 1
fi

echo "Public IP: $PUBLIC_IP"

# Ждем готовности SSH
echo "Waiting for SSH to become available..."
for i in {1..30}; do
    if ssh -o ConnectTimeout=5 "$SSH_USER@$PUBLIC_IP" "echo ok" >/dev/null 2>&1; then
        echo "SSH connection successful"
        break
    fi
    echo "Waiting for SSH... $i/30"
    sleep 10
done

# Устанавливаем Docker и Docker Compose
echo "Installing Docker and Compose on remote server..."
ssh "$SSH_USER@$PUBLIC_IP" <<'EOF'
    set -e
    echo "Removing old Docker versions..."
    sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    echo "Updating system..."
    sudo apt update -y
    
    echo "Installing dependencies..."
    sudo apt install -y ca-certificates curl
    
    echo "Adding Docker repository..."
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    
    echo "Adding Docker repository to sources..."
    sudo bash -c 'cat <<EOT > /etc/apt/sources.list.d/docker.sources
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: '$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")'
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOT'
    
    echo "Installing Docker..."
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    echo "Starting Docker..."
    sudo systemctl enable docker --now
    
    echo "Adding user to docker group..."
    sudo usermod -aG docker $USER
    
    echo "Docker installation complete"
EOF

# Копируем файлы проекта
echo "Copying project files to server..."
scp -r \
    Dockerfile \
    go.mod \
    go.sum \
    main.go \
    docker-compose.yml \
    "$SSH_USER@$PUBLIC_IP:/home/$SSH_USER/"

# Копируем директории
for dir in handlers models utils db; do
    if [ -d "$dir" ]; then
        scp -r "$dir" "$SSH_USER@$PUBLIC_IP:/home/$SSH_USER/"
    fi
done

# Создаем docker-compose.yml на сервере если его нет
ssh "$SSH_USER@$PUBLIC_IP" <<'EOF'
    if [ ! -f docker-compose.yml ]; then
        cat > docker-compose.yml <<'YAML'
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
    restart: unless-stopped

  app:
    build: .
    container_name: app
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
    restart: unless-stopped

volumes:
  postgres_data:
YAML
    fi
EOF

# Собираем и запускаем приложение
echo "Building and starting application on remote server..."
ssh "$SSH_USER@$PUBLIC_IP" <<'EOF'
    set -e
    cd /home/$USER
    
    echo "Building Docker image..."
    sudo docker build -t project-sem1:latest .
    
    echo "Starting services with Docker Compose..."
    sudo docker compose up -d
    
    echo "Waiting for services to start..."
    sleep 15
    
    echo "=== Container Status ==="
    sudo docker compose ps
    
    echo "=== Testing API locally ==="
    curl -f http://localhost:8080/api/v0/prices || echo "API not ready yet"
    
    echo "=== PostgreSQL Status ==="
    sudo docker compose logs postgres --tail 20
EOF

# Сохраняем IP для тестов
echo "PUBLIC_IP=$PUBLIC_IP" >> $GITHUB_ENV
echo "API_HOST=http://$PUBLIC_IP:8080" >> $GITHUB_ENV
echo "DB_HOST=$PUBLIC_IP" >> $GITHUB_ENV

echo "=== Deployment Complete ==="
echo "Server IP: $PUBLIC_IP"
echo "API available at: http://$PUBLIC_IP:8080"
echo ""
echo "To test the API:"
echo "  curl http://$PUBLIC_IP:8080/api/v0/prices?start=2024-01-01&end=2024-01-31&min=100&max=1000"
echo ""
echo "To SSH into the server:"
echo "  ssh ubuntu@$PUBLIC_IP"
echo ""
echo "To delete the VM when done:"
echo "  yc compute instance delete --name $INSTANCE_NAME"

# Сохраняем IP в файл для локального использования
echo "$PUBLIC_IP" > vm_ip.txt