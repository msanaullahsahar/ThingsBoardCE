#!/bin/bash
set -Eeuo pipefail

# ============================================================
# ThingsBoard CE automatic installer
# Raspberry Pi 4/5 - Raspberry Pi OS 64-bit
# ThingsBoard CE 4.3.1.5
# Java 17
# PostgreSQL 16
# Nginx reverse proxy
# ============================================================

TB_VERSION="4.3.1.5"
TB_DB_NAME="thingsboard"
TB_DB_USER="postgres"
TB_DB_PASSWORD=""
TB_HTTP_PORT="8080"
NGINX_PORT="80"
INSTALL_DIR="/opt/thingsboard-installer"
TB_CONF="/etc/thingsboard/conf/thingsboard.conf"
TB_PACKAGE="thingsboard-${TB_VERSION}.deb"
TB_URL="https://github.com/thingsboard/thingsboard/releases/download/v${TB_VERSION}/${TB_PACKAGE}"

START=$(date +%s)

# ------------------------------------------------------------
# Error handling
# ------------------------------------------------------------
trap 'echo; echo "ERROR: Installation failed at line $LINENO."; exit 1' ERR

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    echo "Run: sudo bash $0"
    exit 1
fi

# ------------------------------------------------------------
# OS / architecture checks
# ------------------------------------------------------------
if [ ! -f /etc/os-release ]; then
    echo "ERROR: Cannot determine operating system."
    exit 1
fi

. /etc/os-release

ARCH="$(dpkg --print-architecture)"
RAM_MB="$(free -m | awk '/^Mem:/{print $2}')"
HOSTNAME_SHORT="$(hostname)"
LOCAL_IP="$(hostname -I | awk '{print $1}')"

clear

echo "============================================================"
echo "       ThingsBoard Community Edition Installer"
echo "============================================================"
echo
echo "Operating system : ${PRETTY_NAME:-$ID}"
echo "Architecture     : $ARCH"
echo "Hostname         : $HOSTNAME_SHORT"
echo "RAM              : ${RAM_MB} MB"
echo "ThingsBoard      : $TB_VERSION"
echo

# ------------------------------------------------------------
# Architecture check
# ------------------------------------------------------------
if [ "$ARCH" != "arm64" ]; then
    echo "ERROR: This installer requires a 64-bit ARM operating system."
    echo "Detected architecture: $ARCH"
    echo
    echo "Please install Raspberry Pi OS 64-bit."
    exit 1
fi

# ------------------------------------------------------------
# RAM check
# ------------------------------------------------------------
if [ "$RAM_MB" -lt 3500 ]; then
    echo "WARNING: ThingsBoard recommends at least 4 GB RAM."
    echo "This Raspberry Pi has approximately ${RAM_MB} MB."
    echo
    read -r -p "Continue anyway? [y/N]: " ANSWER
    [[ "$ANSWER" =~ ^[Yy]$ ]] || exit 0
fi

# ------------------------------------------------------------
# Confirmation
# ------------------------------------------------------------
if command -v whiptail >/dev/null 2>&1; then
    whiptail --title "ThingsBoard CE Installation" --yesno "This will install ThingsBoard CE ${TB_VERSION}, Java 17, PostgreSQL 16 and Nginx. Continue?" 10 70 || exit 0
else
    read -r -p "Continue with ThingsBoard installation? [y/N]: " ANSWER
    [[ "$ANSWER" =~ ^[Yy]$ ]] || exit 0
fi

# ------------------------------------------------------------
# PostgreSQL password
# ------------------------------------------------------------
echo
echo "PostgreSQL password is required for the ThingsBoard database."
echo "You can also set it before running the script:"
echo
echo "  sudo TB_DB_PASSWORD='your-password' bash $0"
echo

if [ -z "$TB_DB_PASSWORD" ]; then
    read -r -s -p "Enter PostgreSQL password [default: post24984]: " TB_DB_PASSWORD
    echo
    [ -n "$TB_DB_PASSWORD" ] || TB_DB_PASSWORD="post24984"
fi

# ------------------------------------------------------------
# Package update
# ------------------------------------------------------------
echo
echo "*** Updating Raspberry Pi OS ***"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# ------------------------------------------------------------
# Basic packages
# ------------------------------------------------------------
echo
echo "*** Installing required utilities ***"
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    wget \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    whiptail \
    nginx \
    apt-transport-https

# ------------------------------------------------------------
# Java 17
# ------------------------------------------------------------
echo
echo "*** Installing OpenJDK 17 ***"

DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-17-jdk

JAVA17="$(find /usr/lib/jvm -type f -path '*/bin/java' 2>/dev/null | grep 'java-17' | head -n 1 || true)"

if [ -n "$JAVA17" ]; then
    update-alternatives --set java "$JAVA17" || true
fi

echo
echo "Java version:"
java -version

# ------------------------------------------------------------
# PostgreSQL repository
# ------------------------------------------------------------
echo
echo "*** Configuring PostgreSQL repository ***"

DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-common

if [ ! -f /etc/apt/sources.list.d/pgdg.sources ] && [ ! -f /etc/apt/sources.list.d/pgdg.list ]; then
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh
fi

apt-get update

# ------------------------------------------------------------
# PostgreSQL 16
# ------------------------------------------------------------
echo
echo "*** Installing PostgreSQL 16 ***"

DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-16

systemctl enable postgresql
systemctl start postgresql

echo
echo "*** Waiting for PostgreSQL ***"

for i in {1..30}; do
    if sudo -u postgres pg_isready >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if ! sudo -u postgres pg_isready >/dev/null 2>&1; then
    echo "ERROR: PostgreSQL did not start correctly."
    exit 1
fi

# ------------------------------------------------------------
# PostgreSQL password
# ------------------------------------------------------------
echo
echo "*** Configuring PostgreSQL user ***"

sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER USER postgres WITH PASSWORD '$TB_DB_PASSWORD';"

# ------------------------------------------------------------
# Create ThingsBoard database if necessary
# ------------------------------------------------------------
echo
echo "*** Creating ThingsBoard database ***"

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${TB_DB_NAME}'" | grep -q 1; then
    echo "Database '${TB_DB_NAME}' already exists."
else
    sudo -u postgres createdb "$TB_DB_NAME"
    echo "Database '${TB_DB_NAME}' created."
fi

# ------------------------------------------------------------
# Download ThingsBoard
# ------------------------------------------------------------
echo
echo "*** Downloading ThingsBoard CE ${TB_VERSION} ***"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

if [ ! -f "$TB_PACKAGE" ]; then
    wget --show-progress -O "$TB_PACKAGE" "$TB_URL"
else
    echo "$TB_PACKAGE already exists."
fi

if [ ! -s "$TB_PACKAGE" ]; then
    echo "ERROR: ThingsBoard package is empty or missing."
    exit 1
fi

# ------------------------------------------------------------
# Install ThingsBoard
# ------------------------------------------------------------
echo
echo "*** Installing ThingsBoard CE ${TB_VERSION} ***"

dpkg -i "$INSTALL_DIR/$TB_PACKAGE" || {
    echo
    echo "*** Fixing package dependencies ***"
    apt-get install -f -y
}

# ------------------------------------------------------------
# ThingsBoard configuration
# ------------------------------------------------------------
echo
echo "*** Configuring ThingsBoard ***"

if [ ! -f "$TB_CONF" ]; then
    mkdir -p "$(dirname "$TB_CONF")"
    touch "$TB_CONF"
fi

cp "$TB_CONF" "${TB_CONF}.backup.$(date +%Y%m%d%H%M%S)"

# Remove configuration previously generated by this installer.
sed -i '/^# BEGIN AUTOMATIC RPI CONFIGURATION$/,/^# END AUTOMATIC RPI CONFIGURATION$/d' "$TB_CONF"

cat >> "$TB_CONF" <<EOF

# BEGIN AUTOMATIC RPI CONFIGURATION

# PostgreSQL database
export DATABASE_TS_TYPE=sql
export SPRING_DATASOURCE_URL=jdbc:postgresql://localhost:5432/${TB_DB_NAME}
export SPRING_DATASOURCE_USERNAME=${TB_DB_USER}
export SPRING_DATASOURCE_PASSWORD=${TB_DB_PASSWORD}

# HTTP
export HTTP_BIND_PORT=${TB_HTTP_PORT}

# END AUTOMATIC RPI CONFIGURATION
EOF

chmod 600 "$TB_CONF"

# ------------------------------------------------------------
# JVM memory
# ------------------------------------------------------------
echo
echo "*** Configuring ThingsBoard JVM memory ***"

# ThingsBoard recommends approximately half of available RAM.
if [ "$RAM_MB" -ge 7000 ]; then
    HEAP="4G"
elif [ "$RAM_MB" -ge 5000 ]; then
    HEAP="3G"
elif [ "$RAM_MB" -ge 3500 ]; then
    HEAP="2G"
elif [ "$RAM_MB" -ge 1800 ]; then
    HEAP="1G"
else
    HEAP="768M"
fi

sed -i '/^# BEGIN AUTOMATIC JVM CONFIGURATION$/,/^# END AUTOMATIC JVM CONFIGURATION$/d' "$TB_CONF"

cat >> "$TB_CONF" <<EOF

# BEGIN AUTOMATIC JVM CONFIGURATION
export JAVA_OPTS="\$JAVA_OPTS -Xms${HEAP} -Xmx${HEAP}"
# END AUTOMATIC JVM CONFIGURATION
EOF

echo "ThingsBoard JVM heap: $HEAP"

# ------------------------------------------------------------
# ThingsBoard database initialisation
# ------------------------------------------------------------
echo
echo "*** Initialising ThingsBoard database ***"

if [ ! -f /var/lib/thingsboard/.database_initialised ]; then
    /usr/share/thingsboard/bin/install/install.sh --loadDemo
    mkdir -p /var/lib/thingsboard
    touch /var/lib/thingsboard/.database_initialised
else
    echo "ThingsBoard database has already been initialised."
    echo "Skipping database initialisation."
fi

# ------------------------------------------------------------
# Nginx reverse proxy
# ------------------------------------------------------------
echo
echo "*** Configuring Nginx reverse proxy ***"

cat > /etc/nginx/sites-available/thingsboard <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/thingsboard /etc/nginx/sites-enabled/thingsboard

echo
echo "*** Testing Nginx configuration ***"
nginx -t

systemctl enable nginx
systemctl restart nginx

# ------------------------------------------------------------
# Start ThingsBoard
# ------------------------------------------------------------
echo
echo "*** Starting ThingsBoard ***"

systemctl daemon-reload
systemctl enable thingsboard
systemctl restart thingsboard

# ------------------------------------------------------------
# Wait for ThingsBoard
# ------------------------------------------------------------
echo
echo "*** Waiting for ThingsBoard to start ***"
echo "This can take several minutes on a Raspberry Pi."

TB_READY=0

for i in {1..120}; do
    if curl -fsS "http://127.0.0.1:${TB_HTTP_PORT}/" >/dev/null 2>&1; then
        TB_READY=1
        break
    fi
    sleep 2
done

# ------------------------------------------------------------
# Final information
# ------------------------------------------------------------
LOCAL_IP="$(hostname -I | awk '{print $1}')"
END=$(date +%s)
ELAPSED=$((END-START))

clear

echo "============================================================"
echo "       ThingsBoard CE Installation Complete"
echo "============================================================"
echo
echo "ThingsBoard version : $TB_VERSION"
echo "Raspberry Pi arch   : $ARCH"
echo "RAM                 : ${RAM_MB} MB"
echo "JVM heap            : $HEAP"
echo "PostgreSQL          : 16"
echo
echo "Web interface:"
echo "  http://${LOCAL_IP}/"
echo
echo "Direct ThingsBoard:"
echo "  http://${LOCAL_IP}:8080/"
echo
echo "MQTT:"
echo "  ${LOCAL_IP}:1883"
echo
echo "PostgreSQL:"
echo "  localhost:5432"
echo
echo "Nginx:"
echo "  ${LOCAL_IP}:80 -> ThingsBoard :8080"
echo
echo "Installation time: ${ELAPSED} seconds"
echo

if [ "$TB_READY" -eq 1 ]; then
    echo "ThingsBoard HTTP service: READY"
else
    echo "ThingsBoard HTTP service: NOT READY YET"
    echo
    echo "Check the service with:"
    echo "  sudo systemctl status thingsboard"
    echo
    echo "Check the log with:"
    echo "  sudo journalctl -u thingsboard -n 100 --no-pager"
    echo
    echo "ThingsBoard log:"
    echo "  sudo tail -n 100 /var/log/thingsboard/thingsboard.log"
fi

echo
echo "Services:"
echo "  sudo systemctl status thingsboard"
echo "  sudo systemctl status postgresql"
echo "  sudo systemctl status nginx"
echo
echo "============================================================"
echo "Installation finished."
echo "============================================================"
