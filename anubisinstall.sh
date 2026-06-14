#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root."
  exit 1
fi

echo "========================================================================"
# 1. CONFIGURE APACHE PRE_VIRTUALHOST
# ========================================================================
echo "Step 1: Checking and configuring Apache pre_virtualhost_global..."
APACHE_CONF="/etc/apache2/conf.d/includes/pre_virtualhost_global.conf"
LINE_TO_ADD='SetEnvIf X-Forwarded-Proto "https" HTTPS=on'

mkdir -p "$(dirname "$APACHE_CONF")"

if [ -f "$APACHE_CONF" ] && grep -Fq "$LINE_TO_ADD" "$APACHE_CONF"; then
    echo "-> Line already exists in $APACHE_CONF. Skipping."
else
    echo "$LINE_TO_ADD" >> "$APACHE_CONF"
    echo "-> Successfully added line to $APACHE_CONF."
fi


echo "========================================================================"
# 2. CREATE ANUBIS BOT DETECTION POLICY
# ========================================================================
echo "Step 2: Creating Anubis Bot Detection Policy..."
POLICY_FILE="/opt/anubis-waf/botPolicy.yaml"
mkdir -p "$(dirname "$POLICY_FILE")"

cat << 'EOF' > "$POLICY_FILE"
# ==============================================================================
# ANUBIS WAF HARDENED BOT DETECTION POLICY
# Optimized for Ad Platform Compatibility (Google, Facebook, TikTok)
# ==============================================================================

status_codes:
  CHALLENGE: 200
  DENY: 403

bots:
  # ----------------------------------------------------------------------------
  # TIER 1: CRITICAL WHITELISTS (Bypass lanes evaluated first)
  # ----------------------------------------------------------------------------
  - name: allow-static-assets
    path_regex: '\.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$'
    action: ALLOW

  - name: allow-friendly-crawlers
    user_agent_regex: '(?i)(Googlebot|AdsBot-Google.*|Mediapartners-Google|Google-Display-Ads-Bot|Bingbot|YandexBot|Baiduspider|Better Uptime Bot|facebookexternalhit|facebookcatalog|Meta-ExternalAds|TikTokBot|ByteLocale)'
    action: ALLOW

  # ----------------------------------------------------------------------------
  # TIER 2: HARD BLOCKS (Dropped instantly with a 403)
  # ----------------------------------------------------------------------------
  - name: block-ai-scrapers
    user_agent_regex: '(?i)(GPTBot|ChatGPT-User|ClaudeBot|Claude-Web|Anthropic-AI|PerplexityBot|ImagesiftBot|Omgilibot|Omgimediabot|BytesSpider|CCBot|Diffbot|FacebookBot|Google-Extended)'
    action: DENY

  - name: block-vulnerability-scanners
    user_agent_regex: '(?i)(sqlmap|acunetix|nessus|nmap|nikto|masscan|zgrab|censys|Fuzz|Go-http-client)'
    action: DENY

  # ----------------------------------------------------------------------------
  # TIER 3: AUTH PROTECTION & CATCHALLS
  # ----------------------------------------------------------------------------
  - name: elevate-login-security
    path_regex: '(/index.php/login|/remote.php/dav|/index.php/core/connect|/wp-login.php)'
    action: CHALLENGE
    challenge:
      algorithm: fast
      difficulty: 3

  - name: generic-browser-challenge
    user_agent_regex: '.*'
    action: CHALLENGE
    challenge:
      algorithm: preact
      difficulty: 4
EOF
echo "-> Policy written to $POLICY_FILE."


echo "========================================================================"
# 3. CONFIGURE DOCKER-COMPOSE WITH PUBLIC IP DETECT
# ========================================================================
echo "Step 3: Fetching Public IP and generating docker-compose.yml..."
SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || curl -s https://icanhazip.com)

if [ -z "$SERVER_IP" ]; then
    echo "!!! Warning: Could not detect public IP automatically. Using placeholder 103.27.74.53."
    SERVER_IP="103.27.74.53"
else
    echo "-> Detected Public IP: $SERVER_IP"
fi

DOCKER_COMPOSE_FILE="/opt/anubis-waf/docker-compose.yml"
mkdir -p "$(dirname "$DOCKER_COMPOSE_FILE")"

cat << EOF > "$DOCKER_COMPOSE_FILE"
services:
  anubis:
    image: ghcr.io/techarohq/anubis:latest
    container_name: anubis
    restart: unless-stopped
    network_mode: "host"
    environment:
      - BIND=127.0.0.1:8923
      - DIFFICULTY=4
      - TARGET=http://${SERVER_IP}:81
      - POLICY_FNAME=/data/botPolicy.yaml
      - USE_REMOTE_ADDRESS=true
    volumes:
      - ./botPolicy.yaml:/data/botPolicy.yaml:ro
EOF
echo "-> Configuration written to $DOCKER_COMPOSE_FILE."


echo "========================================================================"
# 4. CONFIGURE NGINX CPANEL PROXY
# ========================================================================
echo "Step 4: Writing cPanel Nginx configurations..."
NGINX_CONF="/etc/nginx/conf.d/includes-optional/cpanel-proxy.conf"
mkdir -p "$(dirname "$NGINX_CONF")"

cat << 'EOF' > "$NGINX_CONF"
# ==============================================================================
# 0. FORCE HTTPS UPGRADE (Fixes Insecure Cookie Drops)
# ==============================================================================
if ($scheme = http) {
    return 301 https://$host$request_uri;
}

# 1. Standard Identity Headers
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

# 2. FORCE CLEAN PROXY TRANSLATION (Fixes Browser 502)
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
proxy_read_timeout 86400;

# 3. Clean Stream Management
proxy_set_header Accept-Encoding "";
proxy_buffering on;
proxy_hide_header Transfer-Encoding;

# 4. Large Buffers for Anubis Challenge Verification
proxy_buffer_size          128k;
proxy_buffers              4 256k;
proxy_busy_buffers_size    256k;

# 5. Hand off tracking target to Anubis WAF
set $CPANEL_APACHE_PROXY_PASS http://127.0.0.1:8923;
EOF
echo "-> Proxy configuration written to $NGINX_CONF."


echo "========================================================================"
# 5. INSTALL REQUIRED PACKAGES
# ========================================================================
echo "Step 5: Installing ea-nginx + ea-nginx-http2 ..."
yum -y install ea-nginx
yum -y install ea-nginx-http2 

echo "Step 6: Checking and installing Docker Environment..."
if ! command -v docker &> /dev/null; then
    echo "-> Docker not found. Installing now..."
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl start docker
    systemctl enable docker
    echo "-> Docker engine successfully installed and enabled."
else
    echo "-> Docker is already installed. Skipping installation."
fi


echo "========================================================================"
# 6. BUILD, REBUILD AND DEPLOY ARCHITECTURE
# ========================================================================
echo "Final Step: Rebuilding web configurations and starting containers..."
/scripts/rebuildhttpdconf
/scripts/ea-nginx config --all
/scripts/restartsrv_httpd

cd /opt/anubis-waf/
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d

echo "========================================================================"
echo "ANUBIS WAF DEPLOYMENT SUCCESSFUL!"
echo "========================================================================"
