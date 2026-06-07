#!/usr/bin/env bash
# MTPSelf manager (telemt edition)
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/telemt}"
COMPOSE=(docker compose -f "${PROJECT_DIR}/docker-compose.yml")
CONFIG="${PROJECT_DIR}/config.toml"

c_g="\033[1;32m"; c_y="\033[1;33m"; c_r="\033[1;31m"; c_b="\033[1;36m"; c_0="\033[0m"
log(){ echo -e "${c_g}[+]${c_0} $*"; }; warn(){ echo -e "${c_y}[!]${c_0} $*"; }
err(){ echo -e "${c_r}[x]${c_0} $*" >&2; }; hr(){ echo -e "${c_b}────────────────────────────────────────────${c_0}"; }
pause(){ echo; read -rp "Enter — назад..." _; }

[ "$(id -u)" -eq 0 ] || { err "sudo mtpself"; exit 1; }
[ -f "${PROJECT_DIR}/docker-compose.yml" ] || { err "Проект не найден в ${PROJECT_DIR}."; exit 1; }

cfg(){ grep -m1 -E "^$1" "${CONFIG}" 2>/dev/null | cut -d'"' -f2; }
secret(){ grep -m1 -oE '"[0-9a-fA-F]{32}"' "${CONFIG}" | tr -d '"' | head -n1; }
build_link(){
  local host dom s domhex
  host="$(cfg public_host)"; dom="$(cfg tls_domain)"; s="$(secret)"
  domhex="$(printf '%s' "${dom}" | od -An -tx1 | tr -d ' \n')"
  echo "tg://proxy?server=${host}&port=443&secret=ee${s}${domhex}"
}

status(){
  hr; "${COMPOSE[@]}" ps; hr
  local n; n="$(ss -tn 'sport = :443' state established 2>/dev/null | tail -n +2 | wc -l || echo '?')"
  echo "  tls_domain : $(cfg tls_domain)"
  echo "  public_host: $(cfg public_host)"
  echo "  Клиентов   : ${n} (активных на :443)"
  docker stats telemt --no-stream --format '  telemt: CPU {{.CPUPerc}} MEM {{.MemUsage}}' 2>/dev/null || true
  pause
}
links(){ hr; echo "  tg:// : $(build_link)"; echo; echo "  t.me  : https://t.me/proxy?$(build_link | cut -d? -f2)"; hr; pause; }
logs(){ warn "Ctrl+C — выход."; "${COMPOSE[@]}" logs -f --tail=100 telemt || true; }
restart(){ "${COMPOSE[@]}" restart; log "Перезапущено."; pause; }
update(){ "${COMPOSE[@]}" pull && "${COMPOSE[@]}" up -d; sleep 3; "${COMPOSE[@]}" ps; log "Обновлено."; pause; }

change_domain(){
  warn "Смена tls_domain инвалидирует старые ee-ссылки (нужно раздать новые)."
  read -rp "  Новый tls_domain (реальный HTTPS-сайт): " d
  d="$(printf '%s' "${d}" | tr -cd 'A-Za-z0-9.-')"; [ -n "${d}" ] || { warn "Отмена."; pause; return; }
  sed -i "s|^tls_domain.*|tls_domain    = \"${d}\"|" "${CONFIG}"
  "${COMPOSE[@]}" restart; log "tls_domain → ${d}. Новая ссылка:"; echo "  $(build_link)"; pause
}
rotate_secret(){
  warn "Ротация секрета: старые ссылки перестанут работать."
  read -rp "  Сгенерировать новый секрет? [y/N]: " ok; [[ "${ok}" =~ ^[Yy]$ ]] || { warn "Отмена."; pause; return; }
  local ns; ns="$(openssl rand -hex 16)"
  sed -i "s|^user = \"[0-9a-fA-F]*\"|user = \"${ns}\"|" "${CONFIG}"
  "${COMPOSE[@]}" restart; log "Новый секрет. Ссылка:"; echo "  $(build_link)"; pause
}
metrics(){ hr; curl -s 127.0.0.1:9090/metrics 2>/dev/null | grep -E 'connection|telegram|traffic' | head -20 || warn "Метрики недоступны."; hr; pause; }
uninstall(){
  read -rp "  Введи UNINSTALL: " ok; [ "${ok}" = "UNINSTALL" ] || { warn "Отмена."; pause; return; }
  "${COMPOSE[@]}" down 2>/dev/null || true
  rm -f /usr/local/bin/mtpself; rm -rf "${PROJECT_DIR}"
  ufw delete allow 443/tcp >/dev/null 2>&1 || true
  log "Удалено."; exit 0
}

menu(){
  clear; hr
  echo -e "  ${c_b}MTPSelf · telemt${c_0}  (домен $(cfg tls_domain))"
  hr
  echo "  1) Статус"; echo "  2) Ссылки"; echo "  3) Логи"; echo "  4) Перезапуск"
  echo "  5) Обновить telemt"; echo "  6) Сменить tls_domain"; echo "  7) Ротация секрета"
  echo "  8) Метрики"; echo "  9) Удалить"; echo "  0) Выход"
  hr; read -rp "  Выбор: " ch
  case "${ch}" in
    1) status;; 2) links;; 3) logs;; 4) restart;; 5) update;;
    6) change_domain;; 7) rotate_secret;; 8) metrics;; 9) uninstall;; 0) exit 0;;
    *) warn "Нет пункта."; sleep 1;;
  esac
}
while true; do menu; done
