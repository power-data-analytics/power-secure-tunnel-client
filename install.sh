#!/bin/bash

# Configuration
POWER_TUNNEL_GATEWAY=${POWER_TUNNEL_GATEWAY:-44.233.132.94}
CLOUD_API_URL="http://${POWER_TUNNEL_GATEWAY}/register-tunnel"
CONFIG_DIR="/etc/power-tunnel"
SERVICE_NAME="power-tunnel"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to print error and exit
error_exit() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

# Check if script is run as root
if [ "$(id -u)" != "0" ]; then
    error_exit "This script must be run as root"
fi

# Install required packages
install_dependencies() {
    echo "Installing required packages..."
    apt-get update -qq && apt-get install -y jq curl -qq
}

install_dependencies

# Check for existing installation
if [ -d "$CONFIG_DIR" ]; then
    echo -e "${YELLOW}Existing tunnel configuration detected.${NC}"

    # Check if current setup is working
    if [ -f "$CONFIG_DIR/config.json" ]; then
        TUNNEL_PORT=$(jq -r '.port' "$CONFIG_DIR/config.json")
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            echo -e "${GREEN}Current tunnel service is running correctly.${NC}"
        else
            echo -e "${YELLOW}Current tunnel service is not running properly.${NC}"
        fi
    fi

    read -p "Do you want to (K)eep the existing configuration or create (N)ew one? [K/n] " CHOICE
    CHOICE=${CHOICE:-K}

    if [[ $CHOICE =~ ^[Kk]$ ]]; then
        echo "Keeping existing configuration."
        exit 0
    elif [[ $CHOICE =~ ^[Nn]$ ]]; then
        echo "Stopping existing service..."
        systemctl stop "${SERVICE_NAME}" 2>/dev/null

        echo "Backing up existing configuration..."
        BACKUP_DIR="${CONFIG_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
        mv "$CONFIG_DIR" "$BACKUP_DIR"
        echo "Existing configuration backed up to: $BACKUP_DIR"
    else
        error_exit "Invalid choice"
    fi
fi

# Create configuration directory
mkdir -p "$CONFIG_DIR" || error_exit "Failed to create config directory"
chmod 700 "$CONFIG_DIR"

# Handle SSH key pair
if [ -f "$CONFIG_DIR/tunnel.key" ]; then
    echo "Using existing SSH key pair"
    # Ensure correct permissions
    chmod 600 "$CONFIG_DIR/tunnel.key"
    if [ ! -f "$CONFIG_DIR/tunnel.key.pub" ]; then
        error_exit "Found private key but public key is missing"
    fi
else
    echo "Generating new SSH key pair..."
    ssh-keygen -t ed25519 -f "$CONFIG_DIR/tunnel.key" -N "" -C "power-tunnel-$(hostname)" || error_exit "Failed to generate SSH key"
    chmod 600 "$CONFIG_DIR/tunnel.key"
fi

# Read the public key
PUBLIC_KEY=$(cat "$CONFIG_DIR/tunnel.key.pub" || error_exit "Failed to read public key")

# Register with cloud service and get configuration
echo "Registering with cloud service..."
# Format JSON payload properly
JSON_PAYLOAD=$(jq -n \
    --arg key "$PUBLIC_KEY" \
    --arg hostname "$(hostname)" \
    '{public_key: $key, hostname: $hostname}')

RESPONSE=$(curl -sSf -X POST "$CLOUD_API_URL" \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD" \
    -o "$CONFIG_DIR/config.json")

if [ $? -ne 0 ]; then
    error_exit "Failed to register with cloud service"
fi

# Extract configuration
TUNNEL_PORT=$(jq -r '.port' "$CONFIG_DIR/config.json")
GATEWAY_IP=$(jq -r '.gateway_ip' "$CONFIG_DIR/config.json")

# Load existing database configuration if available
if [ -f "$CONFIG_DIR/database.conf" ]; then
    source "$CONFIG_DIR/database.conf"
    echo -e "${YELLOW}Found existing database configuration:${NC}"
    echo "Database IP: $DB_IP"
    echo "Database Port: $DB_PORT"
    read -p "Do you want to keep this database configuration? [Y/n] " KEEP_DB
    KEEP_DB=${KEEP_DB:-Y}
    if [[ ! $KEEP_DB =~ ^[Yy]$ ]]; then
        unset DB_IP DB_PORT
    fi
fi

# Get database connection details if not loaded from config
if [ -z "$DB_IP" ]; then
    read -p "Enter database server IP address: " DB_IP
fi
if [ -z "$DB_PORT" ]; then
    read -p "Enter database server port: " DB_PORT
fi

# Validate input
if [[ ! $DB_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error_exit "Invalid IP address format"
fi

if ! [[ "$DB_PORT" =~ ^[0-9]+$ ]] || [ "$DB_PORT" -lt 1 ] || [ "$DB_PORT" -gt 65535 ]; then
    error_exit "Invalid port number"
fi

# Save database configuration
cat > "$CONFIG_DIR/database.conf" << EOL
DB_IP=$DB_IP
DB_PORT=$DB_PORT
EOL
chmod 600 "$CONFIG_DIR/database.conf"

# Create systemd service file
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOL
[Unit]
Description=SSH Reverse Tunnel Service
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c '/usr/bin/ssh-keyscan -H ${GATEWAY_IP} > ${CONFIG_DIR}/known_hosts'
ExecStart=/usr/bin/ssh -i ${CONFIG_DIR}/tunnel.key -N -R ${TUNNEL_PORT}:${DB_IP}:${DB_PORT} -o UserKnownHostsFile=${CONFIG_DIR}/known_hosts -o ServerAliveInterval=60 -o ServerAliveCountMax=3 power_tunnel@${GATEWAY_IP}
Restart=always
RestartSec=60
StartLimitInterval=0

[Install]
WantedBy=multi-user.target
EOL

# Set proper permissions
chmod 644 "/etc/systemd/system/${SERVICE_NAME}.service"

# Reload systemd daemon
systemctl daemon-reload || error_exit "Failed to reload systemd daemon"

# Enable and start the service
echo "Enabling and starting the tunnel service..."
systemctl enable "${SERVICE_NAME}" || error_exit "Failed to enable service"
systemctl start "${SERVICE_NAME}" || error_exit "Failed to start service"

# Check service status with retry
MAX_RETRIES=3
for ((i=1; i<=MAX_RETRIES; i++)); do
    echo "Checking service status (attempt $i of $MAX_RETRIES)..."
    sleep 5
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        echo -e "${GREEN}Tunnel service has been successfully set up and started${NC}"
        echo "You can check the service status with: systemctl status ${SERVICE_NAME}"
        echo "View logs with: journalctl -u ${SERVICE_NAME}"
        break
    fi
    if [ $i -eq $MAX_RETRIES ]; then
        echo -e "${RED}Service failed to start properly after $MAX_RETRIES attempts${NC}"
        echo "Please check logs with: journalctl -u ${SERVICE_NAME}"
        exit 1
    fi
done

# Save configuration for reference
cat > "$CONFIG_DIR/config.txt" << EOL
Tunnel Configuration:
Gateway: ${GATEWAY_IP}
Local Database: ${DB_IP}:${DB_PORT}
Remote Port: ${TUNNEL_PORT}
Last Updated: $(date)
EOL

# Create an uninstall script
cat > "${CONFIG_DIR}/uninstall.sh" << EOL
#!/bin/bash
systemctl stop ${SERVICE_NAME}
systemctl disable ${SERVICE_NAME}
rm -f /etc/systemd/system/${SERVICE_NAME}.service
rm -rf ${CONFIG_DIR}
systemctl daemon-reload
echo "Tunnel service has been uninstalled"
EOL

chmod +x "${CONFIG_DIR}/uninstall.sh"

echo -e "${GREEN}Setup completed successfully!${NC}"
echo "Configuration directory: ${CONFIG_DIR}"
echo "Configuration summary saved to: ${CONFIG_DIR}/config.txt"
echo "To uninstall the service, run: ${CONFIG_DIR}/uninstall.sh"
