#!/bin/bash

# TribeNest Nginx Setup Script
# Simple script to setup nginx with SSL using certbot

set -e



# Check required arguments
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <domain> <email>"
    echo "Example: $0 yourdomain.com admin@yourdomain.com"
    exit 1
fi

DOMAIN_NAME=$1
EMAIL=$2

echo "🚀 Setting up Nginx for TribeNest..."
echo "Domain: $DOMAIN_NAME"
echo "Email: $EMAIL"
echo ""

# Step 0: Check and clean existing nginx configurations
echo "0️⃣  Checking and cleaning existing nginx configurations..."

# Use sudo only if not running as root
SUDO_CMD=""
if [[ $EUID -ne 0 ]]; then
    SUDO_CMD="sudo"
fi

# Check and remove only specific files if they exist
if [[ -f /etc/nginx/sites-enabled/default ]]; then
    echo "🗑️  Removing default nginx site..."
    $SUDO_CMD rm -f /etc/nginx/sites-enabled/default
fi

if [[ -f /etc/nginx/sites-enabled/tribenest ]]; then
    echo "🗑️  Removing existing tribenest site link..."
    $SUDO_CMD rm -f /etc/nginx/sites-enabled/tribenest
fi

if [[ -f /etc/nginx/sites-available/tribenest ]]; then
    echo "🗑️  Removing existing tribenest configuration..."
    $SUDO_CMD rm -f /etc/nginx/sites-available/tribenest
fi

if [[ -f /etc/nginx/conf.d/tribenest.conf ]]; then
    echo "🗑️  Removing existing tribenest conf.d file..."
    $SUDO_CMD rm -f /etc/nginx/conf.d/tribenest.conf
fi

# Ensure nginx has a minimal valid configuration only if conf.d directory exists
if [[ -d /etc/nginx/conf.d ]]; then
    $SUDO_CMD tee /etc/nginx/conf.d/default.conf << EOF
server {
    listen 80 default_server;
    server_name _;
    return 444;
}
EOF
fi

echo "✅ Nginx configuration cleanup completed"

# Step 1: Reinstall nginx
echo "1️⃣  Reinstalling nginx..."

# Detect OS for package manager
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$NAME
    OS_VERSION=$VERSION_ID
else
    echo "❌ Could not detect OS"
    echo "Please install nginx manually and run this script again"
    exit 1
fi

echo "   Detected OS: $OS $OS_VERSION"

# Stop nginx if running
echo "   Stopping nginx service..."
$SUDO_CMD systemctl stop nginx 2>/dev/null || true

case $OS in
    *"Ubuntu"*|*"Debian"*)
        echo "   Using apt package manager..."
        $SUDO_CMD apt update
        $SUDO_CMD apt remove -y nginx nginx-common nginx-full 2>/dev/null || true
        $SUDO_CMD apt autoremove -y
        $SUDO_CMD apt install -y nginx
        ;;
    *"CentOS"*|*"Red Hat"*|*"Amazon Linux"*)
        echo "   Using yum package manager..."
        $SUDO_CMD yum remove -y nginx 2>/dev/null || true
        $SUDO_CMD yum install -y nginx
        $SUDO_CMD systemctl enable nginx
        ;;
    *"Alpine"*)
        echo "   Using apk package manager..."
        apk del nginx 2>/dev/null || true
        apk add nginx
        ;;
    *"Fedora"*)
        echo "   Using dnf package manager..."
        $SUDO_CMD dnf remove -y nginx 2>/dev/null || true
        $SUDO_CMD dnf install -y nginx
        $SUDO_CMD systemctl enable nginx
        ;;
    *)
        echo "❌ Unsupported OS: $OS"
        echo "Please install nginx manually for your OS and run this script again"
        exit 1
        ;;
esac

# Verify installation
if command -v nginx &> /dev/null; then
    echo "✅ Nginx reinstalled successfully"
    nginx_version=$(nginx -v 2>&1 | cut -d'/' -f2)
    echo "   Version: $nginx_version"
else
    echo "❌ Nginx installation failed"
    exit 1
fi

# Step 2: Add simplified nginx config
echo "2️⃣  Adding nginx configuration..."

$SUDO_CMD tee /etc/nginx/sites-available/tribenest << EOF
# TribeNest Production Configuration
server {
    listen 80;
    server_name ${DOMAIN_NAME};

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        client_max_body_size 500M;
        proxy_request_buffering off;

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF

# Enable the site
if [[ -d /etc/nginx/sites-enabled ]]; then
    $SUDO_CMD ln -sf /etc/nginx/sites-available/tribenest /etc/nginx/sites-enabled/
    $SUDO_CMD rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
else
    $SUDO_CMD cp /etc/nginx/sites-available/tribenest /etc/nginx/conf.d/tribenest.conf
fi

echo "✅ Nginx configuration added"

# Step 3: Test and restart nginx
echo "3️⃣  Testing and restarting nginx..."

# Stop any existing nginx processes
$SUDO_CMD systemctl stop nginx 2>/dev/null || true

# Check if port 80 is in use and stop conflicting services
if command -v netstat &> /dev/null; then
    if $SUDO_CMD netstat -tlnp | grep :80 > /dev/null 2>&1; then
        echo "⚠️  Port 80 is already in use. Stopping conflicting services..."
        $SUDO_CMD systemctl stop apache2 2>/dev/null || true
        $SUDO_CMD systemctl stop httpd 2>/dev/null || true
        $SUDO_CMD systemctl stop lighttpd 2>/dev/null || true
    fi
fi

# Test configuration
$SUDO_CMD nginx -t

# Start nginx
$SUDO_CMD systemctl enable nginx
$SUDO_CMD systemctl start nginx

# Verify nginx is running
if $SUDO_CMD systemctl is-active --quiet nginx; then
    echo "✅ Nginx started successfully"
else
    echo "❌ Nginx failed to start. Checking logs..."
    $SUDO_CMD journalctl -u nginx --no-pager -n 10
    exit 1
fi

# Step 4: Install certbot if not available
echo "4️⃣  Installing certbot..."
if ! command -v certbot &> /dev/null; then
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
    fi
    
    case $OS in
        *"Ubuntu"*|*"Debian"*)
            $SUDO_CMD apt update
            $SUDO_CMD apt install -y certbot python3-certbot-nginx
            ;;
        *"CentOS"*|*"Red Hat"*|*"Amazon Linux"*)
            $SUDO_CMD yum install -y certbot python3-certbot-nginx
            ;;
        *)
            echo "❌ Please install certbot manually for your OS"
            exit 1
            ;;
    esac
    echo "✅ Certbot installed"
else
    echo "✅ Certbot already installed"
fi

# Step 5: Run certbot to generate wildcard certificate
echo "5️⃣  Generating wildcard SSL certificate..."
echo ""
echo "⚠️  IMPORTANT: For wildcard certificates, you need to add DNS TXT records."
echo "⚠️  Make sure your domain ${DOMAIN_NAME} points to this server's IP address"
echo ""
echo "The certificate generation will pause and ask you to add DNS records."
echo "You'll need to add a TXT record for _acme-challenge.${DOMAIN_NAME}"
echo ""
echo "Press Enter when you're ready to continue..."
read

# Run certbot with wildcard certificate
echo "🚀 Starting wildcard certificate generation..."
echo "📝 Certbot will pause and ask you to add DNS records."
echo "   Look for the TXT record instructions in the output below:"
echo ""

$SUDO_CMD certbot certonly --manual --preferred-challenges=dns -d ${DOMAIN_NAME} -d *.${DOMAIN_NAME} --agree-tos --email ${EMAIL}
echo "✅ Wildcard SSL certificate generated"

# Step 6: Update nginx configuration with SSL
echo "6️⃣  Updating nginx configuration with SSL..."
$SUDO_CMD tee /etc/nginx/sites-available/tribenest << EOF
# TribeNest Production Configuration with SSL
server {
    listen 80;
    server_name ${DOMAIN_NAME} *.${DOMAIN_NAME};

    # Redirect all HTTP traffic to HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN_NAME} *.${DOMAIN_NAME};

    # SSL configuration
    ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem;
    
    # SSL security settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        client_max_body_size 500M;

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF
echo "✅ SSL configuration applied"

# Step 7: Restart nginx
echo "7️⃣  Restarting nginx with SSL..."
$SUDO_CMD systemctl restart nginx
echo "✅ Nginx restarted with SSL"

echo ""
echo "🎉 Setup complete!"
echo "Your site is now available at: https://${DOMAIN_NAME}"
echo ""
echo "To check nginx status: sudo systemctl status nginx"
echo "To view nginx logs: sudo journalctl -u nginx" 