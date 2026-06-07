#!/usr/bin/env bash
#
# MTPSelf (telemt edition) — self-hosted Telegram MTProto proxy on telemt (Rust).
# Stronger masking: transparent TCP-splice to a real tls_domain + TLS record emulation.
# For Ubuntu 24.04 / Debian 12+.
#
#   curl -fsSLo /tmp/install.sh https://raw.githubusercontent.com/SkunkBG/MTPSelf/main/install.sh
#   sudo bash /tmp/install.sh
#
set -euo pipefail

MTP_TAG="${MTP_TAG:-latest}"               # тег образа telemt (latest или, напр., 3.3.28)
TLS_DOMAIN="${TLS_DOMAIN:-}"               # SNI-домен маскировки (реальный HTTPS-сайт)
DEFAULT_TLS_DOMAIN="www.microsoft.com"
PROXY_PORT="${PROXY_PORT:-443}"
PROJECT_DIR="${PROJECT_DIR:-/opt/telemt}"
SSH_PORT="${SSH_PORT:-}"
RAW_BASE="https://raw.githubusercontent.com/SkunkBG/MTPSelf/main"

c_g="\033[1;32m"; c_y="\033[1;33m"; c_r="\033[1;31m"; c_b="\033[1;36m"; c_0="\033[0m"
log()  { echo -e "${c_g}[+]${c_0} $*"; }
warn() { echo -e "${c_y}[!]${c_0} $*"; }
die()  { echo -e "${c_r}[x]${c_0} $*" >&2; exit 1; }
hr()   { echo -e "${c_b}────────────────────────────────────────────${c_0}"; }

[ "$(id -u)" -eq 0 ] || die "Запусти от root: sudo bash install.sh"

if [ -r /etc/os-release ]; then . /etc/os-release; fi
case "${ID:-}" in ubuntu|debian) : ;; *) warn "Рассчитано на Ubuntu/Debian (${ID:-unknown}). Продолжаю как Debian." ;; esac
CODENAME="${VERSION_CODENAME:-stable}"
case "${ID:-debian}" in
  ubuntu) DOCKER_DISTRO="ubuntu" ;; debian) DOCKER_DISTRO="debian" ;;
  *) case "${ID_LIKE:-debian}" in *ubuntu*) DOCKER_DISTRO="ubuntu" ;; *) DOCKER_DISTRO="debian" ;; esac ;;
esac
if [ -z "${SSH_PORT}" ]; then
  SSH_PORT="$(grep -sE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1 || true)"
  SSH_PORT="${SSH_PORT:-22}"
fi

# ── tls_domain ──
if [ -z "${TLS_DOMAIN}" ] && [ -t 0 ]; then
  echo "  SNI-домен маскировки: реальный HTTPS-сайт (TLS 1.3), достижимый с сервера."
  echo "  telemt прозрачно сплайсит к нему весь не-Telegram трафик."
  read -rp "  tls_domain [${DEFAULT_TLS_DOMAIN}]: " TLS_DOMAIN
fi
TLS_DOMAIN="$(printf '%s' "${TLS_DOMAIN:-$DEFAULT_TLS_DOMAIN}" | tr -cd 'A-Za-z0-9.-')"
[ -n "${TLS_DOMAIN}" ] || TLS_DOMAIN="${DEFAULT_TLS_DOMAIN}"

# ── Docker ──
if ! command -v docker >/dev/null 2>&1; then
  log "Устанавливаю Docker Engine (${DOCKER_DISTRO}, ${CODENAME})..."
  apt-get update -y; apt-get install -y ca-certificates curl gnupg jq openssl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/${DOCKER_DISTRO} ${CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  log "Docker уже установлен ($(docker --version | awk '{print $3}' | tr -d ','))."
  command -v jq      >/dev/null 2>&1 || apt-get install -y jq
  command -v openssl >/dev/null 2>&1 || apt-get install -y openssl
  docker compose version >/dev/null 2>&1 || apt-get install -y docker-compose-plugin || warn "Нет docker compose plugin."
fi

# ── Каталог ──
mkdir -p "${PROJECT_DIR}"; cd "${PROJECT_DIR}"

# ── Публичный IP ──
SRV_IP="$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || curl -fsS4 --max-time 5 https://ifconfig.me 2>/dev/null || true)"
[ -n "${SRV_IP}" ] || { SRV_IP="$(hostname -I | awk '{print $1}')"; warn "Не определил внешний IP, беру локальный ${SRV_IP}."; }

# ── config.toml (ASCII; генерим только если нет) ──
if [ ! -f config.toml ]; then
  SECRET="$(openssl rand -hex 16)"     # 32 hex-символа
  cat > config.toml <<EOF
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure  = false
tls     = true

[general.links]
show        = "*"
public_host = "${SRV_IP}"
public_port = ${PROXY_PORT}

[server]
port           = ${PROXY_PORT}
metrics_listen = "127.0.0.1:9090"

[server.api]
enabled   = true
listen    = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"]

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain    = "${TLS_DOMAIN}"
mask          = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
user = "${SECRET}"
EOF
  chmod 600 config.toml
  log "config.toml создан (tls_domain=${TLS_DOMAIN})."
else
  warn "config.toml уже есть — не трогаю."
fi

# ── docker-compose.yml ──
if [ ! -f docker-compose.yml ]; then
  if [ -f "$(dirname "${BASH_SOURCE[0]}")/docker-compose.yml" ]; then
    cp "$(dirname "${BASH_SOURCE[0]}")/docker-compose.yml" docker-compose.yml
  else
    curl -fsSLo docker-compose.yml "${RAW_BASE}/docker-compose.yml"
  fi
fi
# подставим тег образа, если задан не latest
sed -i "s|ghcr.io/telemt/telemt:[A-Za-z0-9._-]*|ghcr.io/telemt/telemt:${MTP_TAG}|" docker-compose.yml

# ── UFW ──
if ! command -v ufw >/dev/null 2>&1; then apt-get install -y ufw; fi
ufw allow "${SSH_PORT}/tcp"   comment 'SSH'     >/dev/null
ufw allow "${PROXY_PORT}/tcp" comment 'MTProto' >/dev/null
ufw --force enable >/dev/null
log "UFW: открыты ${SSH_PORT}/tcp и ${PROXY_PORT}/tcp."

# ── Менеджер ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/mtpself.sh" ]; then cp "${SCRIPT_DIR}/mtpself.sh" "${PROJECT_DIR}/mtpself.sh"
else curl -fsSLo "${PROJECT_DIR}/mtpself.sh" "${RAW_BASE}/mtpself.sh" 2>/dev/null || warn "Не скачал mtpself.sh."; fi
[ -f "${PROJECT_DIR}/mtpself.sh" ] && { chmod +x "${PROJECT_DIR}/mtpself.sh"; ln -sf "${PROJECT_DIR}/mtpself.sh" /usr/local/bin/mtpself; log "Команда: mtpself"; }

# ── Старт ──
docker compose pull
docker compose up -d
sleep 5
hr; docker compose ps; hr

# ── Ссылка (считаем ee-секрет сами: ee + secret + hex(tls_domain)) ──
SECRET="$(grep -m1 -oE '"[0-9a-fA-F]{32}"' config.toml | tr -d '"' | head -n1)"
DOMHEX="$(printf '%s' "${TLS_DOMAIN}" | od -An -tx1 | tr -d ' \n')"
EE="ee${SECRET}${DOMHEX}"
LINK="tg://proxy?server=${SRV_IP}&port=${PROXY_PORT}&secret=${EE}"
TME="https://t.me/proxy?server=${SRV_IP}&port=${PROXY_PORT}&secret=${EE}"
log "Ссылки для подключения:"
hr
echo "  Domain (FakeTLS): ${TLS_DOMAIN}"
echo "  tg://  : ${LINK}"
echo "  t.me   : ${TME}"
hr
echo -e "  Управление: ${c_b}mtpself${c_0}   |   Логи: docker compose -f ${PROJECT_DIR}/docker-compose.yml logs -f"
echo "  (telemt также печатает ссылки в логах при старте.)"
hr
log "Готово."
