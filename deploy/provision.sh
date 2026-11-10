#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# Main provisioning script for mataroa, tested with Debian 13
# This script sets up a fresh server with all required dependencies and configurations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration from .envrc if it exists
if [ -f "${SCRIPT_DIR}/.envrc" ]; then
    echo "==> Loading configuration from .envrc..."
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.envrc"
else
    echo "ERROR: .envrc file not found. Copy .envrc.example to .envrc and configure it."
    exit 1
fi

# Check required variables
if [ -z "${SERVER_IP:-}" ]; then
    echo "ERROR: SERVER_IP is not set in .envrc"
    exit 1
fi

if [ -z "${SERVER_USER:-}" ]; then
    echo "ERROR: SERVER_USER is not set in .envrc"
    exit 1
fi

echo "==> Provisioning mataroa on ${SERVER_IP} as ${SERVER_USER}..."
echo ""

# Generate systemd files
echo "==> Generating systemd configuration files..."
"${SCRIPT_DIR}/generate-systemd-files.sh"
SYSTEMD_FILES="${SCRIPT_DIR}/generated"

# Function to run commands on remote server
run_remote() {
    ssh cohorte-vps "$@"
}

# 1. Install essential packages
echo "==> Installing essential packages..."
run_remote "sudo apt update && sudo apt install -y gcc git rclone vim postgresql postgresql-contrib curl gettext-base btop gpg"

# 2. Install Caddy
echo "==> Installing Caddy..."
run_remote "bash -s" < "${SCRIPT_DIR}/install-caddy.sh"

# 3. Create deploy user
echo "==> Creating deploy user..."
run_remote "
    if ! id -u deploy &>/dev/null; then
        sudo useradd -m -s /bin/bash -G sudo,www-data deploy
        mkdir -p /home/deploy/.ssh
        ssh-keygen -t ed25519 -f /home/deploy/.ssh/id_ed25519 -N '' -C "deploy@mataroa"
        sudo chown -R deploy:deploy /home/deploy/.ssh
        echo 'deploy user created successfully'
    else
        echo 'deploy user already exists'
    fi
"

# 4. Create /var/www directory
echo "==> Creating /var/www directory..."
run_remote "sudo mkdir -p /var/www && sudo chown deploy:www-data /var/www && sudo chmod 755 /var/www"

# 5. Setup PostgreSQL database
echo "==> Setting up PostgreSQL database..."
run_remote "
    export POSTGRES_USERNAME='${POSTGRES_USERNAME}'
    export POSTGRES_PASSWORD='${POSTGRES_PASSWORD}'
    bash -s
" < "${SCRIPT_DIR}/setup-database.sh"

# 6. Install uv as deploy user
echo "==> Installing uv for deploy user..."
run_remote "sudo -u deploy bash -c 'curl -LsSf https://astral.sh/uv/0.9.11/install.sh | sh'"

# 7. Clone repository
echo "==> Cloning mataroa repository..."
run_remote "
    if [ -d /var/www/mataroa ]; then
        echo 'Repository already exists, pulling latest changes...'
        sudo -u deploy bash -c 'cd /var/www/mataroa && git pull'
    else
        sudo -u deploy git clone https://github.com/mataroablog/mataroa /var/www/mataroa
    fi
"

# 8. Install Python dependencies
echo "==> Installing Python dependencies..."
run_remote "sudo -u deploy bash -c 'cd /var/www/mataroa && /home/deploy/.local/bin/uv sync --all-groups'"

# 9. Deploy systemd files
echo "==> Deploying systemd configuration files..."
(cd "${SYSTEMD_FILES}" && tar cf - .) | run_remote "
    mkdir -p /tmp/mataroa-deploy
    tar -C /tmp/mataroa-deploy -xf -
    cd /tmp/mataroa-deploy

    # Move files to destinations
    sudo mv mataroa.service /etc/systemd/system/
    sudo mv mataroa.env /etc/systemd/system/
    sudo chmod 640 /etc/systemd/system/mataroa.env
    sudo mv Caddyfile /etc/caddy/
    sudo mv caddy.service /etc/systemd/system/

    # Move timers and services
    sudo mv mataroa-notifications.timer /etc/systemd/system/
    sudo mv mataroa-notifications.service /etc/systemd/system/
    sudo mv mataroa-exports.timer /etc/systemd/system/
    sudo mv mataroa-exports.service /etc/systemd/system/
    sudo mv mataroa-backup.timer /etc/systemd/system/
    sudo mv mataroa-backup.service /etc/systemd/system/
    sudo mv mataroa-dailysummary.timer /etc/systemd/system/
    sudo mv mataroa-dailysummary.service /etc/systemd/system/
    sudo mv mataroa-renewal.timer /etc/systemd/system/
    sudo mv mataroa-renewal.service /etc/systemd/system/

    # Cleanup
    cd /
    rm -rf /tmp/mataroa-deploy
"

# 10. Setup rclone
echo "==> Setting up rclone..."
run_remote "
    export RCLONE_PROVIDER='${RCLONE_PROVIDER:-}'
    export RCLONE_ACCESS_KEY_ID='${RCLONE_ACCESS_KEY_ID:-}'
    export RCLONE_SECRET_ACCESS_KEY='${RCLONE_SECRET_ACCESS_KEY:-}'
    export RCLONE_REGION='${RCLONE_REGION:-}'
    export RCLONE_ENDPOINT='${RCLONE_ENDPOINT:-}'
    bash -s
" < "${SCRIPT_DIR}/setup-rclone.sh"

# 11. Run Django migrations and collectstatic
echo "==> Running Django migrations..."
run_remote "sudo -u deploy bash -c 'cd /var/www/mataroa && export DATABASE_URL=\"${DATABASE_URL}\" && /home/deploy/.local/bin/uv run python manage.py migrate --no-input'"

echo "==> Collecting static files..."
run_remote "sudo -u deploy bash -c 'cd /var/www/mataroa && /home/deploy/.local/bin/uv run python manage.py collectstatic --no-input'"

# 12. Reload systemd and enable services
echo "==> Enabling and starting systemd services..."
run_remote "
    sudo systemctl daemon-reload
    sudo systemctl enable mataroa
    sudo systemctl enable caddy
    sudo systemctl enable mataroa-notifications.timer
    sudo systemctl enable mataroa-exports.timer
    sudo systemctl enable mataroa-backup.timer
    sudo systemctl enable mataroa-dailysummary.timer
    sudo systemctl enable mataroa-renewal.timer
    sudo systemctl start mataroa-notifications.timer
    sudo systemctl start mataroa-exports.timer
    sudo systemctl start mataroa-backup.timer
    sudo systemctl start mataroa-dailysummary.timer
    sudo systemctl start mataroa-renewal.timer
    sudo systemctl start mataroa
    sudo systemctl start caddy
"

# 13. Wait and restart Caddy
echo "==> Waiting for 30 seconds before restarting Caddy..."
run_remote "
    sleep 30
    sudo systemctl restart caddy
"

echo ""
echo "==> ✓ Provisioning completed successfully!"
