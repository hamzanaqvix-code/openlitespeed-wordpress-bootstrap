#!/bin/bash
# =============================================================================
# OpenLiteSpeed WordPress Bootstrap Script
# Stack: OpenLiteSpeed 1.9 + PHP 8.2 (LSAPI) + MariaDB 10.11 + Redis 7
# Security: Shorewall 5.2 + Fail2ban
# Target: Debian 11/12
# Author: Muhammad Hamza
# GitHub: https://github.com/hamzanaqvix-code/openlitespeed-wordpress-bootstrap
#
# Port map:
#   OLS :80 (public) -> PHP 8.2 LSAPI (direct, no proxy layer)
#   MariaDB :3306 (localhost only)
#   Redis :6379 (localhost only)
#   OLS Admin :7080 (localhost only — use SSH tunnel to access)
# =============================================================================

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export UCF_FORCE_CONFFOLD=true
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# -----------------------------------------------------------------------------
# VARIABLES — edit before running
# -----------------------------------------------------------------------------
APP_NAME="myapp"
DB_NAME="${APP_NAME}_db"
DB_USER="${APP_NAME}_user"
DB_PASS=$(openssl rand -base64 16)
WEBROOT="/var/www/${APP_NAME}/public_html"
PHP_VERSION="82"
PHP_VERSION_DOT="8.2"
REDIS_PORT="6379"
OLS_ADMIN_USER="admin"
OLS_ADMIN_PASS=$(openssl rand -base64 12)

# -----------------------------------------------------------------------------
# COLORS
# -----------------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()     { echo -e "${GREEN}[OK]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }

# -----------------------------------------------------------------------------
# ROOT CHECK
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root."
fi

# -----------------------------------------------------------------------------
# DETECT DEBIAN VERSION
# -----------------------------------------------------------------------------
section "Detecting OS"
DEBIAN_VERSION=$(cat /etc/debian_version | cut -d. -f1)
if [[ "$DEBIAN_VERSION" -lt 11 ]]; then
    error "This script requires Debian 11 or 12."
fi
log "Debian $DEBIAN_VERSION detected."

# -----------------------------------------------------------------------------
# STEP 1: System update
# -----------------------------------------------------------------------------
section "Updating system packages"
apt-get update -qq
apt-get upgrade -y -qq \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
apt-get install -y -qq \
    curl wget gnupg2 ca-certificates lsb-release \
    apt-transport-https software-properties-common \
    openssl ufw cron logrotate git
log "System updated."

# -----------------------------------------------------------------------------
# STEP 2: Create application directories
# -----------------------------------------------------------------------------
section "Creating application directories"
mkdir -p "${WEBROOT}"
mkdir -p "/var/www/${APP_NAME}/logs"
mkdir -p "/var/www/${APP_NAME}/tmp"
chown -R nobody:nogroup "/var/www/${APP_NAME}"
chmod -R 755 "/var/www/${APP_NAME}"
log "Directories created at /var/www/${APP_NAME}."

# -----------------------------------------------------------------------------
# STEP 3: Install OpenLiteSpeed
# -----------------------------------------------------------------------------
section "Installing OpenLiteSpeed"
wget -qO - https://repo.litespeed.sh | bash
apt-get update -qq
apt-get install -y -qq openlitespeed

# Set admin credentials non-interactively
echo "${OLS_ADMIN_USER}:$(openssl passwd -apr1 ${OLS_ADMIN_PASS})" > \
    /usr/local/lsws/admin/conf/htpasswd

systemctl enable lsws
systemctl start lsws
log "OpenLiteSpeed installed."

# -----------------------------------------------------------------------------
# STEP 4: Install PHP 8.2 via LSAPI
# NOTE: OLS repo uses lsphp82 package prefix
# gd, mbstring, xml, zip, bcmath, soap are bundled in lsphp82-common
# -----------------------------------------------------------------------------
section "Installing PHP ${PHP_VERSION_DOT} LSAPI"
apt-get install -y -qq \
    lsphp${PHP_VERSION} \
    lsphp${PHP_VERSION}-common \
    lsphp${PHP_VERSION}-mysql \
    lsphp${PHP_VERSION}-redis \
    lsphp${PHP_VERSION}-curl \
    lsphp${PHP_VERSION}-intl \
    lsphp${PHP_VERSION}-imap \
    lsphp${PHP_VERSION}-imagick \
    lsphp${PHP_VERSION}-opcache \
    lsphp${PHP_VERSION}-memcached \
    lsphp${PHP_VERSION}-igbinary

log "PHP ${PHP_VERSION_DOT} LSAPI installed."

# -----------------------------------------------------------------------------
# STEP 5: Configure OpenLiteSpeed
# OLS default vhost is named 'Example' — we update its docRoot and listener
# to serve our application on port 80 with PHP 8.2
# -----------------------------------------------------------------------------
section "Configuring OpenLiteSpeed"

# Change listener from default port 8088 to port 80
sed -i 's/address                  \*:8088/address                  *:80/' \
    /usr/local/lsws/conf/httpd_config.conf

# Update extProcessor to use lsphp82 explicitly
sed -i "s|path                            lsphp83/bin/lsphp|path                            lsphp${PHP_VERSION}/bin/lsphp|" \
    /usr/local/lsws/conf/httpd_config.conf 2>/dev/null || true

# Update Example vhost docRoot to our webroot
sed -i "s|docRoot \$VH_ROOT/html/|docRoot ${WEBROOT}/|" \
    /usr/local/lsws/conf/vhosts/Example/vhconf.conf

# Add index.php and enable rewrite for WordPress
sed -i 's/indexFiles index.html/indexFiles index.php, index.html/' \
    /usr/local/lsws/conf/vhosts/Example/vhconf.conf

sed -i '/rewrite {/{n;s/enable 0/enable 1/}' \
    /usr/local/lsws/conf/vhosts/Example/vhconf.conf

# Restart OLS to apply config
/usr/local/lsws/bin/lswsctrl restart
sleep 3
log "OpenLiteSpeed configured on port 80 with PHP ${PHP_VERSION_DOT} LSAPI."

# -----------------------------------------------------------------------------
# STEP 6: Install MariaDB 10.11 LTS
# -----------------------------------------------------------------------------
section "Installing MariaDB 10.11"
curl -LsSO https://downloads.mariadb.com/MariaDB/mariadb_repo_setup
bash mariadb_repo_setup --mariadb-server-version="mariadb-10.11"
rm -f mariadb_repo_setup
apt-get update -qq
apt-get install -y -qq mariadb-server mariadb-client
systemctl enable mariadb
systemctl start mariadb

mysql -u root << EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
log "MariaDB installed and configured."

# -----------------------------------------------------------------------------
# STEP 7: Install Redis 7
# -----------------------------------------------------------------------------
section "Installing Redis"
apt-get install -y -qq redis-server
sed -i "s/^bind 127.0.0.1 ::1/bind 127.0.0.1/" /etc/redis/redis.conf
sed -i "s/^port 6379/port ${REDIS_PORT}/" /etc/redis/redis.conf
systemctl enable redis-server
systemctl restart redis-server
log "Redis installed on port ${REDIS_PORT}."

# -----------------------------------------------------------------------------
# STEP 8: Deploy stack verification page
# -----------------------------------------------------------------------------
section "Deploying test page"
cat > "${WEBROOT}/index.php" << 'PHPEOF'
<?php
$checks = [];
$checks['PHP Version']    = PHP_VERSION;
$checks['PHP Handler']    = php_sapi_name();

try {
    $pdo = new PDO(
        'mysql:host=127.0.0.1;dbname=' . getenv('DB_NAME'),
        getenv('DB_USER'),
        getenv('DB_PASS')
    );
    $checks['MariaDB'] = 'Connected successfully';
} catch (Exception $e) {
    $checks['MariaDB'] = 'Failed: ' . $e->getMessage();
}

try {
    $redis = new Redis();
    $redis->connect('127.0.0.1', 6379);
    $redis->set('ols_test', 'ok');
    $checks['Redis'] = $redis->get('ols_test') === 'ok'
        ? 'Connected and read/write verified'
        : 'Connected but read/write failed';
} catch (Exception $e) {
    $checks['Redis'] = 'Failed: ' . $e->getMessage();
}

$checks['Server Software'] = $_SERVER['SERVER_SOFTWARE'] ?? 'Unknown';
$checks['OPcache']         = function_exists('opcache_get_status') ? 'Enabled' : 'Not loaded';
$checks['Imagick']         = extension_loaded('imagick') ? 'Loaded' : 'Not loaded';

echo "<h2>OpenLiteSpeed Stack Status</h2><ul>";
foreach ($checks as $k => $v) {
    echo "<li><strong>{$k}:</strong> {$v}</li>";
}
echo "</ul>";
echo "<p><small>Stack: OpenLiteSpeed + PHP ${PHP_VERSION_DOT} LSAPI + MariaDB + Redis</small></p>";
PHPEOF

chown -R nobody:nogroup "/var/www/${APP_NAME}"
log "Test page deployed at ${WEBROOT}."

# -----------------------------------------------------------------------------
# STEP 9: Install and configure Shorewall
# NOTE: Shorewall 5.2.x does not use SECTION keyword in rules file
# SSH/ACCEPT macro handles rate limiting automatically
# -----------------------------------------------------------------------------
section "Installing Shorewall"
apt-get install -y -qq shorewall

PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
log "Primary network interface: ${PRIMARY_IF}"

cat > /etc/shorewall/zones << 'ZONESEOF'
fw      firewall
net     ipv4
ZONESEOF

cat > /etc/shorewall/interfaces << IFEOF
net     ${PRIMARY_IF}    detect          dhcp,tcpflags,nosmurfs,routefilter,logmartians
IFEOF

cat > /etc/shorewall/policy << 'POLICYEOF'
net             fw              DROP            info
fw              net             ACCEPT
all             all             REJECT          info
POLICYEOF

# SSH/ACCEPT macro handles rate limiting
# OLS admin port 7080 is NOT opened publicly — access via SSH tunnel only
cat > /etc/shorewall/rules << 'RULESEOF'
#ACTION         SOURCE          DEST            PROTO   DEST    SOURCE  ORIGINAL RATE
#                                                       PORT    PORT    DEST     LIMIT

SSH/ACCEPT      net             fw
ACCEPT          net             fw              tcp     80
ACCEPT          net             fw              tcp     443
RULESEOF

# Disable UFW to avoid iptables conflicts
ufw disable 2>/dev/null || true

shorewall check
shorewall start
systemctl enable shorewall
log "Shorewall configured. Zones: net -> fw. Allowed: SSH, HTTP, HTTPS."

# -----------------------------------------------------------------------------
# STEP 10: Install and configure Fail2ban
# Jails: sshd, wordpress-auth, wordpress-xmlrpc, ols-badbots
# Ban action: shorewall (integrates with Shorewall firewall)
# -----------------------------------------------------------------------------
section "Installing Fail2ban"
apt-get install -y -qq fail2ban

cat > /etc/fail2ban/jail.local << JAILEOF
[DEFAULT]
bantime          = 3600
findtime         = 600
maxretry         = 5
backend          = systemd
banaction        = shorewall
banaction_allports = shorewall

[sshd]
enabled          = true
port             = ssh
filter           = sshd
logpath          = /var/log/auth.log
maxretry         = 3
bantime          = 86400

[wordpress-auth]
enabled          = true
filter           = wordpress-auth
logpath          = /var/www/${APP_NAME}/logs/ols_access.log
maxretry         = 5
findtime         = 300
bantime          = 3600
port             = http,https

[wordpress-xmlrpc]
enabled          = true
filter           = wordpress-xmlrpc
logpath          = /var/www/${APP_NAME}/logs/ols_access.log
maxretry         = 2
findtime         = 60
bantime          = 86400
port             = http,https

[ols-badbots]
enabled          = true
filter           = apache-badbots
logpath          = /var/www/${APP_NAME}/logs/ols_access.log
maxretry         = 2
bantime          = 86400
port             = http,https
JAILEOF

cat > /etc/fail2ban/filter.d/wordpress-auth.conf << 'WPEOF'
[Definition]
failregex = ^<HOST> .* "POST /wp-login\.php
            ^<HOST> .* "POST /wp-admin/admin-ajax\.php.*action=login
ignoreregex =
WPEOF

cat > /etc/fail2ban/filter.d/wordpress-xmlrpc.conf << 'XMLEOF'
[Definition]
failregex = ^<HOST> .* "POST /xmlrpc\.php
ignoreregex =
XMLEOF

cat > /etc/fail2ban/action.d/shorewall.conf << 'SWEOF'
[Definition]
actionstart =
actionstop  =
actioncheck =
actionban   = shorewall drop <ip>
actionunban = shorewall allow <ip>

[Init]
SWEOF

systemctl enable fail2ban
systemctl start fail2ban
log "Fail2ban installed. Jails: sshd, wordpress-auth, wordpress-xmlrpc, ols-badbots."

# -----------------------------------------------------------------------------
# SUMMARY
# -----------------------------------------------------------------------------
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo "=============================================="
echo "   OpenLiteSpeed Bootstrap Complete"
echo "=============================================="
echo ""
echo "  Server IP        : ${SERVER_IP}"
echo "  Webroot          : ${WEBROOT}"
echo "  PHP Version      : ${PHP_VERSION_DOT} (LSAPI - no FPM layer)"
echo ""
echo "  SERVICES:"
echo "  OpenLiteSpeed :80   (HTTP)"
echo "  MariaDB       :3306 (localhost only)"
echo "  Redis         :${REDIS_PORT}  (localhost only)"
echo ""
echo "  OLS ADMIN PANEL (localhost only):"
echo "  Access via SSH tunnel:"
echo "  ssh -L 7080:127.0.0.1:7080 root@${SERVER_IP}"
echo "  Then open: http://127.0.0.1:7080"
echo "  Username : ${OLS_ADMIN_USER}"
echo "  Password : ${OLS_ADMIN_PASS}"
echo ""
echo "  DATABASE:"
echo "  Name     : ${DB_NAME}"
echo "  User     : ${DB_USER}"
echo "  Password : ${DB_PASS}"
echo ""
echo "  SECURITY:"
echo "  Firewall : Shorewall (zones: net, fw)"
echo "  IPS      : Fail2ban (jails: sshd, wp-auth, xmlrpc, badbots)"
echo ""
echo "  Test URL : http://${SERVER_IP}/index.php"
echo ""
echo "  SAVE THESE CREDENTIALS - they will not be shown again."
echo "=============================================="
