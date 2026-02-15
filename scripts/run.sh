#!/bin/bash
set -e
set -o pipefail

YC_FOLDER_ID=$YC_FOLDER_ID
YC_ZONE=${YC_ZONE:-ru-central1-a}
YC_TOKEN=$YC_TOKEN
YC_IMAGE_ID="fd8bnguet48kpk4ovt1u"
INSTANCE_NAME="prices-app-$(date +%s)"
SSH_USER="ubuntu"
PUBLIC_KEY=$PUBLIC_KEY
PRIVATE_KEY=$PRIVATE_KEY
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"

mkdir -p "$HOME/.ssh"
echo "$PUBLIC_KEY" >"$SSH_KEY_PATH.pub"
echo "$PRIVATE_KEY" >"$SSH_KEY_PATH"
cat >$HOME/.ssh/config <<EOF
Host *
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking no
EOF

chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub

cat >cloud-init.yaml <<EOF
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

yc config set token $YC_TOKEN

echo "Creating VM..."
YC_INSTANCE_ID=$(yc compute instance create \
    --name "$INSTANCE_NAME" \
    --folder-id "$YC_FOLDER_ID" \
    --zone "$YC_ZONE" \
    --network-interface subnet-name=default-$YC_ZONE,nat-ip-version=ipv4 \
    --create-boot-disk size=20,image-id="$YC_IMAGE_ID" \
    --memory=2 \
    --cores=2 \
    --metadata-from-file user-data=cloud-init.yaml \
    --format json | jq -r '.id')

echo "Instance ID: $YC_INSTANCE_ID"

PUBLIC_IP=$(yc compute instance get --id "$YC_INSTANCE_ID" --format json | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')

echo "Public IP: $PUBLIC_IP"

echo "Trying to SSH..."
for i in {1..20}; do
    if ssh -o ConnectTimeout=10 "$SSH_USER@$PUBLIC_IP" "echo ok" >/dev/null 2>&1; then
        break
    fi
    echo "waiting... $i/20"
    sleep 10
done

echo "Installing Docker and Compose..."
ssh "$SSH_USER@$PUBLIC_IP" <<'EOF'
sudo apt update -y
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo bash -c 'cat <<EOT > /etc/apt/sources.list.d/docker.sources
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: '$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")'
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOT'

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable docker --now
sudo usermod -aG docker $USER
EOF

# Создаем docker-compose.yml
cat > docker-compose.yml <<EOF
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
    image: $FULL_IMAGE_NAME
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
EOF

echo "Copying deployment files..."
scp docker-compose.yml "$SSH_USER@$PUBLIC_IP:/home/$SSH_USER/"

echo "Starting Docker Compose..."
ssh "$SSH_USER@$PUBLIC_IP" <<EOF
cd /home/$SSH_USER
sudo docker compose pull
sudo docker compose up -d
EOF

echo "PUBLIC_IP=$PUBLIC_IP" >>$GITHUB_ENV
echo "API_HOST=http://$PUBLIC_IP:8080" >>$GITHUB_ENV
echo "DB_HOST=$PUBLIC_IP" >>$GITHUB_ENV