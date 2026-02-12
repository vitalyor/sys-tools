#!/usr/bin/env bash
set -euo pipefail

# ====== Пути ======
RN_INSTALL_DIR="/opt"
RN_NODE_DIR="${RN_INSTALL_DIR}/remnanode"
RN_DATA_DIR="/var/lib/remnanode"

RN_CADDY_DIR="${RN_INSTALL_DIR}/caddy"
RN_CADDY_HTML_DIR="${RN_CADDY_DIR}/html"

# ====== Дефолты ======
RN_DEFAULT_NODE_PORT="2222"      # твой стандарт
RN_DEFAULT_SELFSTEAL_PORT="443"  # чаще всего
RN_DEFAULT_TEMPLATE_FOLDER="google"

# --------------------------
# Helpers
# --------------------------
rn_require_ubuntu_debian() { sys_ensure_apt || return 1; }

rn_install_packages() {
  rn_require_ubuntu_debian || return 1
  sys_need_sudo
  sudo apt-get update -y
  sudo apt-get install -y "$@"
}

rn_ensure_dir() {
  local d="$1"
  sudo mkdir -p "$d"
}

rn_docker_installed() { sys_cmd_exists docker; }
rn_compose_available() { docker compose version >/dev/null 2>&1; }

rn_port_in_use() {
  local port="$1"
  sudo ss -lntup 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
}

rn_port_who_uses() {
  local port="$1"
  sudo ss -lntup 2>/dev/null | grep -E "[:.]${port}\s" || true
}

rn_require_free_port_or_abort() {
  local port="$1"
  local purpose="$2"
  sys_need_sudo
  if rn_port_in_use "$port"; then
    ui_fail "Порт ${port} уже занят (${purpose})."
    ui_info "Кто слушает:"
    rn_port_who_uses "$port"
    echo
    ui_warn "Выбери другой порт, иначе сервис не запустится (network_mode: host)."
    return 1
  fi
  return 0
}

rn_get_server_ip() { sys_public_ip; }

# --------------------------
# Docker install (Ubuntu 22/24)
# --------------------------
rn_install_docker() {
  ui_h1 "RemnaNode — установка Docker (Ubuntu 22/24)"
  sys_need_sudo
  rn_require_ubuntu_debian || { ui_pause; return 1; }

  if rn_docker_installed && rn_compose_available; then
    ui_ok "Docker и docker compose уже установлены."
    ui_pause
    return 0
  fi

  ui_warn "Будет установлен Docker Engine + docker compose plugin."
  ui_confirm "Продолжить?" "Y" || { ui_info "Отменено."; ui_pause; return 0; }

  ui_info "Шаг 1/4: зависимости"
  rn_install_packages ca-certificates curl gnupg lsb-release

  ui_info "Шаг 2/4: Docker repo keyring"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  local codename=""
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  [[ -z "$codename" ]] && codename="$(lsb_release -cs 2>/dev/null || true)"

  ui_info "Шаг 3/4: добавляем репозиторий (codename=${codename})"
  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  ui_info "Шаг 4/4: установка"
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  ui_ok "Docker установлен."
  docker --version || true
  docker compose version || true
  ui_pause
}

# --------------------------
# DNS-check
# --------------------------
rn_dns_check() {
  local domain="$1"
  local server_ip="$2"

  ui_info "DNS-check: домен ${domain} должен указывать на ${server_ip}"

  if ! sys_cmd_exists dig; then
    ui_info "Устанавливаю dnsutils (dig)..."
    rn_install_packages dnsutils
  fi

  local dns_ip=""
  dns_ip="$(dig +short "$domain" A | tail -n 1 || true)"
  if [[ -z "$dns_ip" ]]; then
    ui_fail "DNS-check: A запись не найдена для ${domain}"
    return 1
  fi

  if [[ "$dns_ip" != "$server_ip" ]]; then
    ui_fail "DNS-check: домен указывает на ${dns_ip}, сервер имеет IP ${server_ip}"
    return 1
  fi

  ui_ok "DNS-check OK: ${domain} -> ${dns_ip}"
  return 0
}

# --------------------------
# Xray-core install
# --------------------------
rn_install_xray_core() {
  ui_h1 "RemnaNode — установка Xray-core"

  sys_need_sudo
  rn_require_ubuntu_debian || { ui_pause; return 1; }
  rn_ensure_dir "$RN_DATA_DIR"

  rn_install_packages wget unzip

  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64) arch="64" ;;
    aarch64|arm64) arch="arm64-v8a" ;;
    armv7l|armv6l) arch="arm32-v7a" ;;
    *) ui_fail "Неподдерживаемая архитектура: $(uname -m)"; ui_pause; return 1 ;;
  esac

  ui_info "Архитектура Xray: ${arch}"
  ui_info "Получаю последнюю версию через GitHub API..."

  local api tag
  api="$(curl -fsSL --connect-timeout 10 --max-time 30 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" || true)"
  [[ -z "$api" ]] && { ui_fail "Не удалось получить данные с GitHub API"; ui_pause; return 1; }

  tag="$(echo "$api" | grep -oP '"tag_name":\s*"\K[^"]+' | head -n 1 || true)"
  [[ -z "$tag" ]] && { ui_fail "Не удалось извлечь tag_name"; ui_pause; return 1; }

  ui_ok "Версия Xray-core: ${tag}"

  local filename="Xray-linux-${arch}.zip"
  local url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${filename}"

  ui_info "Скачиваю: ${url}"
  ( cd "$RN_DATA_DIR" && sudo wget --timeout=30 --tries=3 -q "$url" -O "$filename" )

  ui_info "Распаковка..."
  sudo unzip -o "${RN_DATA_DIR}/${filename}" -d "$RN_DATA_DIR" >/dev/null
  sudo rm -f "${RN_DATA_DIR}/${filename}"

  [[ ! -f "${RN_DATA_DIR}/xray" ]] && { ui_fail "Не найден ${RN_DATA_DIR}/xray"; ui_pause; return 1; }
  sudo chmod +x "${RN_DATA_DIR}/xray"

  ui_ok "Xray-core установлен."
  "${RN_DATA_DIR}/xray" version 2>/dev/null | head -n 1 || true
  ui_pause
}

# --------------------------
# RemnaNode deploy
# --------------------------
rn_write_node_files() {
  local node_port="$1"
  local secret_key="$2"
  local install_xray="$3"   # true/false

  sys_need_sudo
  rn_ensure_dir "$RN_NODE_DIR"
  rn_ensure_dir "$RN_DATA_DIR"

  ui_info "Пишу ${RN_NODE_DIR}/.env"
  sudo tee "${RN_NODE_DIR}/.env" >/dev/null <<EOF
NODE_PORT=${node_port}
SECRET_KEY=${secret_key}
EOF

  ui_info "Пишу ${RN_NODE_DIR}/docker-compose.yml"
  sudo tee "${RN_NODE_DIR}/docker-compose.yml" >/dev/null <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ghcr.io/remnawave/node:latest
    env_file:
      - .env
    network_mode: host
    restart: always
EOF

  if [[ "$install_xray" == "true" ]]; then
    sudo tee -a "${RN_NODE_DIR}/docker-compose.yml" >/dev/null <<EOF
    volumes:
      - ${RN_DATA_DIR}/xray:/usr/local/bin/xray
      - /dev/shm:/dev/shm
EOF
  else
    sudo tee -a "${RN_NODE_DIR}/docker-compose.yml" >/dev/null <<'EOF'
    # volumes:
    #   - /dev/shm:/dev/shm
EOF
  fi

  ui_ok "Файлы RemnaNode созданы."
}

rn_node_up() {
  ui_h1 "RemnaNode — запуск контейнера"
  sys_need_sudo

  rn_docker_installed || { ui_fail "Docker не установлен."; ui_pause; return 1; }
  rn_compose_available || { ui_fail "docker compose недоступен."; ui_pause; return 1; }

  ui_info "docker compose up -d в ${RN_NODE_DIR}"
  ( cd "$RN_NODE_DIR" && sudo docker compose up -d )
  ui_ok "RemnaNode запущен."
  ui_pause
}

rn_node_install_flow() {
  ui_h1 "Установка RemnaNode (node + optional Xray)"

  rn_install_docker

  local node_port
  node_port="$(ui_input "NODE_PORT (порт API ноды на хосте)" "$RN_DEFAULT_NODE_PORT")"
  if ! [[ "$node_port" =~ ^[0-9]+$ ]] || (( node_port < 1 || node_port > 65535 )); then
    ui_fail "Некорректный порт: $node_port"
    ui_pause
    return 1
  fi

  if ! rn_require_free_port_or_abort "$node_port" "NODE_PORT (API ноды)"; then
    ui_pause
    return 1
  fi

  local secret_key
  secret_key="$(ui_input "SECRET_KEY (ключ ноды)" "")"
  [[ -z "${secret_key// }" ]] && { ui_fail "SECRET_KEY пустой — так нельзя."; ui_pause; return 1; }

  local install_xray="false"
  if ui_confirm "Установить Xray-core на хост (для монтирования в контейнер)?" "Y"; then
    if rn_install_xray_core; then
      install_xray="true"
    else
      ui_warn "Xray-core не установлен. Продолжу без него."
      install_xray="false"
    fi
  fi

  rn_write_node_files "$node_port" "$secret_key" "$install_xray"
  rn_node_up
}

# --------------------------
# Caddy selfsteal
# --------------------------
rn_template_prepare() {
  sys_need_sudo
  rn_ensure_dir "$RN_CADDY_HTML_DIR"
  sudo rm -rf "${RN_CADDY_HTML_DIR:?}/"* 2>/dev/null || true

  # минимальный шаблон (без внешних зависимостей)
  sudo tee "${RN_CADDY_HTML_DIR}/index.html" >/dev/null <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><title>OK</title></head>
<body style="font-family:system-ui; padding:40px">
<h2>Selfsteal</h2>
<p>Шаблон установлен минимальный. Позже можно расширить выбор шаблонов.</p>
</body></html>
EOF
}

rn_caddy_write_compose_and_caddyfile() {
  local domain="$1"
  local self_port="$2"
  local use_wildcard="$3"         # true/false
  local cf_token="$4"             # optional

  sys_need_sudo
  rn_ensure_dir "$RN_CADDY_DIR"
  rn_ensure_dir "$RN_CADDY_HTML_DIR"
  rn_ensure_dir "${RN_CADDY_DIR}/logs"

  local image="caddy:2.10.2"
  if [[ "$use_wildcard" == "true" ]]; then
    image="caddybuilds/caddy-cloudflare:latest"
  fi

  ui_info "Пишу ${RN_CADDY_DIR}/.env"
  sudo tee "${RN_CADDY_DIR}/.env" >/dev/null <<EOF
SELF_STEAL_DOMAIN=${domain}
SELF_STEAL_PORT=${self_port}
EOF

  if [[ "$use_wildcard" == "true" ]]; then
    echo "CLOUDFLARE_API_TOKEN=${cf_token}" | sudo tee -a "${RN_CADDY_DIR}/.env" >/dev/null
  fi

  ui_info "Пишу ${RN_CADDY_DIR}/docker-compose.yml"
  sudo tee "${RN_CADDY_DIR}/docker-compose.yml" >/dev/null <<EOF
services:
  caddy:
    image: ${image}
    container_name: caddy-selfsteal
    restart: unless-stopped
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ${RN_CADDY_HTML_DIR}:/var/www/html
      - ./logs:/var/log/caddy
      - caddy_data:/data
      - caddy_config:/config
    env_file:
      - .env
    network_mode: "host"
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  caddy_data:
  caddy_config:
EOF

  ui_info "Пишу ${RN_CADDY_DIR}/Caddyfile"
  if [[ "$use_wildcard" == "true" ]]; then
    sudo tee "${RN_CADDY_DIR}/Caddyfile" >/dev/null <<'EOF'
{
	https_port {$SELF_STEAL_PORT}
	auto_https disable_redirects
}

http://{$SELF_STEAL_DOMAIN} {
	bind 0.0.0.0
	redir https://{$SELF_STEAL_DOMAIN}{uri} permanent
}

https://{$SELF_STEAL_DOMAIN} {
	tls {
		dns cloudflare {env.CLOUDFLARE_API_TOKEN}
	}
	root * /var/www/html
	try_files {path} /index.html
	file_server
}

:80 {
	bind 0.0.0.0
	respond 204
}
EOF
  else
    sudo tee "${RN_CADDY_DIR}/Caddyfile" >/dev/null <<'EOF'
{
	https_port {$SELF_STEAL_PORT}
	auto_https disable_redirects
}

http://{$SELF_STEAL_DOMAIN} {
	bind 0.0.0.0
	redir https://{$SELF_STEAL_DOMAIN}{uri} permanent
}

https://{$SELF_STEAL_DOMAIN} {
	root * /var/www/html
	try_files {path} /index.html
	file_server
}

:80 {
	bind 0.0.0.0
	respond 204
}
EOF
  fi

  ui_ok "Caddy selfsteal конфиги созданы."
}

rn_caddy_up() {
  ui_h1 "Caddy selfsteal — запуск"
  sys_need_sudo

  rn_docker_installed || { ui_fail "Docker не установлен."; ui_pause; return 1; }
  rn_compose_available || { ui_fail "docker compose недоступен."; ui_pause; return 1; }

  ( cd "$RN_CADDY_DIR" && sudo docker compose up -d )
  ui_ok "Caddy selfsteal запущен."
  ui_pause
}

rn_caddy_install_flow() {
  ui_h1 "Установка Caddy selfsteal (DNS-check + cert)"

  rn_install_docker

  local domain
  domain="$(ui_input "Домен (совпадает с realitySettings.serverNames)" "")"
  [[ -z "${domain// }" ]] && { ui_fail "Домен пустой."; ui_pause; return 1; }

  local self_port
  self_port="$(ui_input "SELF_STEAL_PORT (порт Caddy на хосте)" "$RN_DEFAULT_SELFSTEAL_PORT")"
  if ! [[ "$self_port" =~ ^[0-9]+$ ]] || (( self_port < 1 || self_port > 65535 )); then
    ui_fail "Некорректный порт: $self_port"
    ui_pause
    return 1
  fi

  if ! rn_require_free_port_or_abort "$self_port" "SELF_STEAL_PORT (Caddy selfsteal)"; then
    ui_pause
    return 1
  fi

  local server_ip
  server_ip="$(rn_get_server_ip)"
  ui_info "IP сервера: ${server_ip}"

  if ! rn_dns_check "$domain" "$server_ip"; then
    ui_warn "DNS-check не прошёл."
    ui_confirm "Продолжить несмотря на это?" "N" || { ui_info "Отменено."; ui_pause; return 0; }
  fi

  ui_info "Тип сертификата:"
  echo "1) Обычный (HTTP-01)"
  echo "2) Wildcard (DNS-01 через Cloudflare)"
  local choice
  choice="$(ui_input "Выбор 1/2" "1")"

  local use_wildcard="false"
  local cf_token=""
  if [[ "$choice" == "2" ]]; then
    use_wildcard="true"
    cf_token="$(ui_input "Cloudflare API Token (Zone Read + DNS Edit)" "")"
    [[ -z "${cf_token// }" ]] && { ui_fail "Cloudflare token пустой."; ui_pause; return 1; }
  fi

  # шаблон (сейчас минимальный, позже расширим)
  local _tmpl
  _tmpl="$(ui_input "Шаблон selfsteal (пока игнорируется, будет минимальный)" "$RN_DEFAULT_TEMPLATE_FOLDER")"
  rn_template_prepare

  rn_caddy_write_compose_and_caddyfile "$domain" "$self_port" "$use_wildcard" "$cf_token"
  rn_caddy_up
}

rn_status() {
  ui_h1 "RemnaNode / Caddy — статус"
  sys_need_sudo

  ui_info "Контейнеры (remnanode|caddy-selfsteal):"
  sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E "remnanode|caddy-selfsteal" || ui_warn "Не вижу контейнеров remnanode/caddy-selfsteal"
  echo

  ui_info "Listening ports (ss -lntuop):"
  sudo ss -lntuop | head -n 120 || true
  ui_pause
}

# --------------------------
# MENU
# --------------------------
plugin_remnanode_menu() {
  while true; do
    ui_clear
    ui_h1 "Меню: RemnaNode (единый ключ)"
    echo "1) Установить Docker + docker compose"
    echo "2) Установить Xray-core (в /var/lib/remnanode/xray)"
    echo "3) Установить/настроить RemnaNode (SECRET_KEY, NODE_PORT=${RN_DEFAULT_NODE_PORT})"
    echo "4) Установить/настроить Caddy selfsteal (DNS-check, cert, порт=${RN_DEFAULT_SELFSTEAL_PORT})"
    echo "5) Статус RemnaNode/Caddy"
    echo "0) Назад"
    echo
    read -rp "Выбор: " c || true
    case "${c:-}" in
      1) rn_install_docker ;;
      2) rn_install_xray_core ;;
      3) rn_node_install_flow ;;
      4) rn_caddy_install_flow ;;
      5) rn_status ;;
      0) return 0 ;;
      *) ui_warn "Неверный выбор."; ui_pause ;;
    esac
  done
}
