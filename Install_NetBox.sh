#!/bin/bash
set -e

# ──────────── [INPUTS INTERATIVOS + VALIDAÇÃO] ──────────────
read -p "Digite a URL do NetBox (ex: netbox.lab.liptech.com.br): " NETBOX_DOMAIN

# Função de validação de senha
validar_senha() {
    local senha="$1"
    if [[ ${#senha} -lt 8 || ! "$senha" =~ [A-Z] || ! "$senha" =~ [a-z] || ! "$senha" =~ [0-9] ]]; then
        echo
        echo "⚠️  Senha inválida!"
        echo "A senha deve conter pelo menos 8 caracteres, incluindo letras maiúsculas, minúsculas e números."
        echo "Password must be at least 8 characters long and contain uppercase letters, lowercase letters, and numbers."
        echo
        return 1
    fi
    return 0
}

# Solicita senha do Redis
while true; do
    read -s -p "Digite a senha do Redis: " REDIS_PASSWORD
    echo
    validar_senha "$REDIS_PASSWORD" && break
done

# Solicita senha do banco de dados
while true; do
    read -s -p "Digite a senha do banco de dados NetBox: " DB_PASSWORD
    echo
    validar_senha "$DB_PASSWORD" && break
done

# Verificação extra da URL
[[ -z "$NETBOX_DOMAIN" ]] && echo "URL do NetBox não pode ficar em branco!" && exit 1

SECRET_KEY_FILE="/opt/netbox/netbox/generate_secret_key.py"

echo "[1/12] Atualizando sistema..."
sudo apt update && sudo apt upgrade -y

echo "[2/12] Instalando dependências..."
sudo apt install -y python3 python3-venv python3-pip \
postgresql postgresql-contrib redis nginx git \
build-essential libpq-dev libxml2-dev libxslt1-dev \
libffi-dev libssl-dev zlib1g-dev

echo "[3/12] Configurando Redis..."
sudo sed -i "s/^#* *requirepass .*$/requirepass ${REDIS_PASSWORD}/" /etc/redis/redis.conf
sudo systemctl restart redis

echo "[4/12] Configurando PostgreSQL..."
sudo -u postgres psql <<EOF
DROP DATABASE IF EXISTS netbox;
DROP USER IF EXISTS netbox;
CREATE DATABASE netbox;
CREATE USER netbox WITH PASSWORD '${DB_PASSWORD}';
ALTER DATABASE netbox OWNER TO netbox;
EOF

echo "[5/12] Clonando NetBox..."
sudo git clone -b master https://github.com/netbox-community/netbox.git /opt/netbox
cd /opt/netbox
sudo cp netbox/netbox/configuration_example.py netbox/netbox/configuration.py

echo "[6/12] Configurando NetBox..."
SECRET_KEY=$(python3 ${SECRET_KEY_FILE})
sudo sed -i "s|^SECRET_KEY = .*|SECRET_KEY = '${SECRET_KEY}'|" netbox/netbox/configuration.py
sudo sed -i "s/ALLOWED_HOSTS = .*/ALLOWED_HOSTS = ['${NETBOX_DOMAIN}']/g" netbox/netbox/configuration.py
sudo sed -i "s/'NAME': .*/'NAME': 'netbox',/" netbox/netbox/configuration.py
sudo sed -i "s/'USER': .*/'USER': 'netbox',/" netbox/netbox/configuration.py
sudo sed -i "s/'PASSWORD': .*/'PASSWORD': '${DB_PASSWORD}',/" netbox/netbox/configuration.py
sudo sed -i "s/'HOST': .*/'HOST': 'localhost',/" netbox/netbox/configuration.py

# Substitui bloco CACHES
sudo sed -i '/^CACHES = {/,/^}/d' netbox/netbox/configuration.py
cat <<EOC | sudo tee -a netbox/netbox/configuration.py > /dev/null

CACHES = {
    'default': {
        'BACKEND': 'django_redis.cache.RedisCache',
        'LOCATION': 'redis://127.0.0.1:6379/0',
        'OPTIONS': {
            'CLIENT_CLASS': 'django_redis.client.DefaultClient',
            'PASSWORD': '${REDIS_PASSWORD}',
        }
    }
}
EOC

echo "[7/12] Criando ambiente virtual..."
sudo python3 -m venv /opt/netbox/venv
/opt/netbox/venv/bin/pip install --upgrade pip
/opt/netbox/venv/bin/pip install -r requirements.txt

echo "[8/12] Migrando banco de dados e criando superusuário..."
export DJANGO_SETTINGS_MODULE=netbox.settings
/opt/netbox/venv/bin/python3 netbox/manage.py migrate

DJANGO_SETTINGS_MODULE=netbox.settings /opt/netbox/venv/bin/python3 netbox/manage.py shell <<EOF
from django.contrib.auth import get_user_model
User = get_user_model()
User.objects.create_superuser('admin', 'admin@example.com', 'admin123')
EOF

/opt/netbox/venv/bin/python3 netbox/manage.py collectstatic --noinput

echo "[9/12] Criando serviço NetBox (Gunicorn)..."
sudo tee /etc/systemd/system/netbox.service > /dev/null <<EOL
[Unit]
Description=NetBox WSGI Service
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/netbox
Environment="DJANGO_SETTINGS_MODULE=netbox.settings"
ExecStart=/opt/netbox/venv/bin/gunicorn --workers 3 --bind 127.0.0.1:8001 --chdir /opt/netbox/netbox netbox.wsgi:application
Restart=always

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable --now netbox

echo "[10/12] Configurando NGINX..."
sudo tee /etc/nginx/sites-available/netbox > /dev/null <<EOL
server {
    listen 80;
    server_name ${NETBOX_DOMAIN};

    client_max_body_size 25m;

    location /static/ {
        alias /opt/netbox/netbox/static/;
    }

    location / {
        proxy_pass http://127.0.0.1:8001;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    access_log /var/log/nginx/netbox_access.log;
    error_log /var/log/nginx/netbox_error.log;
}
EOL

sudo ln -sf /etc/nginx/sites-available/netbox /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

echo "[11/12] Limpando pacotes antigos..."
sudo apt autoremove -y

echo "[12/12] Instalação finalizada!"
echo "→ Acesse: http://${NETBOX_DOMAIN}"
echo "→ Login: admin | Senha: admin123"
