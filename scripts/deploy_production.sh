#!/usr/bin/env bash
# ==============================================================================
# VantageNews Production Automated Deployment Script
# Target OS: Ubuntu 22.04+ / Debian 12 / Linux with systemd
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

echo "============================================================"
echo "          VANTAGE NEWS - PRODUCTION DEPLOYMENT             "
echo "============================================================"

# 1. Check Root Privileges
if [[ $EUID -ne 0 ]]; then
   log_fail "This script must be run as root (or with sudo)."
fi

# 2. Check / Install Docker & Docker Compose
log_info "Checking Docker & Docker Compose installation..."
if ! command -v docker &> /dev/null; then
    log_info "Installing Docker Engine..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release ufw
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    log_pass "Docker installed successfully."
else
    log_pass "Docker is already installed."
fi

# 3. Setup Project Directory
APP_DIR="/opt/vantagenews"
log_info "Setting up application directory at ${APP_DIR}..."
if [[ ! -d "${APP_DIR}" ]]; then
    git clone https://github.com/CitrusCandy/VantageNews.git "${APP_DIR}"
fi

cd "${APP_DIR}"
git fetch --all --tags
git checkout main
git pull origin main

# 4. Generate Production Secrets if .env doesn't exist
if [[ ! -f ".env" ]]; then
    log_info "Generating production .env configuration with cryptographically secure random keys..."
    cp backend/.env.example .env

    # Generate secure keys
    PG_PASS=$(openssl rand -hex 24)
    OPS_KEY=$(openssl rand -hex 32)
    ADMIN_KEY=$(openssl rand -hex 32)
    SEC_KEY=$(openssl rand -hex 32)

    sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PG_PASS}|g" .env
    sed -i "s|OPS_API_KEY=.*|OPS_API_KEY=${OPS_KEY}|g" .env
    sed -i "s|ADMIN_API_KEY=.*|ADMIN_API_KEY=${ADMIN_KEY}|g" .env
    sed -i "s|SECURITY_API_KEY=.*|SECURITY_API_KEY=${SEC_KEY}|g" .env
    sed -i "s|DATABASE_URL=.*|DATABASE_URL=postgresql://postgres:${PG_PASS}@db:5432/vantage_news|g" .env
    sed -i "s|GOVERNANCE_BACKEND=.*|GOVERNANCE_BACKEND=redis|g" .env
    sed -i "s|REDIS_URL=.*|REDIS_URL=redis://redis:6379/0|g" .env

    log_pass "Created .env with generated secrets. (Remember to configure OPENAI_API_KEY and your public domain!)"
else
    log_info "Existing .env found. Preserving current secrets."
fi

# 5. Configure Host Firewall
log_info "Configuring firewall (UFW)..."
if command -v ufw &> /dev/null; then
    ufw allow 22/tcp || true
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
    ufw --force enable || true
    log_pass "Firewall rules applied."
fi

# 6. Build and Launch Containers
log_info "Building and launching production container services..."
docker compose -f docker-compose.prod.yml down --remove-orphans || true
docker compose -f docker-compose.prod.yml up -d --build

# 7. Wait for Health Probes
log_info "Waiting for services to become healthy..."
sleep 10

HEALTH_RETRIES=15
HEALTH_OK=false

for i in $(seq 1 $HEALTH_RETRIES); do
    if curl -sf http://127.0.0.1/health > /dev/null; then
        HEALTH_OK=true
        break
    fi
    log_info "Waiting for /health probe (attempt $i/$HEALTH_RETRIES)..."
    sleep 3
done

if [[ "$HEALTH_OK" = true ]]; then
    log_pass "Liveness probe /health is OK (HTTP 200)."
else
    log_fail "Liveness probe /health failed. Check container logs with 'docker compose -f docker-compose.prod.yml logs'."
fi

# 8. Verify Readiness Probe
READY_STATUS=$(curl -s http://127.0.0.1/ready || echo '{"status":"failed"}')
log_info "Readiness probe result: ${READY_STATUS}"

# 9. Start Background Worker Scheduler
ADMIN_KEY=$(grep '^ADMIN_API_KEY=' .env | cut -d '=' -f2-)
if [[ -n "$ADMIN_KEY" && "$ADMIN_KEY" != "your_primary_admin_api_key_here" ]]; then
    log_info "Starting background worker scheduler..."
    WORKER_RESP=$(curl -s -X POST "http://127.0.0.1/api/workers/start?auto_discover=true" \
        -H "X-Admin-Key: ${ADMIN_KEY}" || echo '{"status":"failed"}')
    log_info "Worker start response: ${WORKER_RESP}"
fi

echo "============================================================"
log_pass "Vantage News has been deployed successfully!"
echo "============================================================"
echo "Local endpoints:"
echo "  - Frontend: http://localhost/"
echo "  - API:      http://localhost/api/"
echo "  - Health:   http://localhost/health"
echo "  - Ready:    http://localhost/ready"
echo "  - Metrics:  http://localhost/metrics"
echo ""
echo "Next step: Point your DNS A record to this server's public IP and run Certbot to enable HTTPS."
