#!/usr/bin/env bash
set -euo pipefail

sys_need_bash() {
  if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This tool requires bash." >&2
    exit 1
  fi
}

sys_cmd_exists() { command -v "$1" >/dev/null 2>&1; }

sys_need_sudo() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if ! sudo -n true 2>/dev/null; then
      # интерактивный sudo ок, просто предупреждение
      return 0
    fi
  fi
}

sys_os_pretty() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${PRETTY_NAME:-unknown}"
  else
    echo "unknown"
  fi
}

sys_public_ip() {
  curl -fsS ifconfig.me 2>/dev/null || echo "N/A"
}

sys_default_iface() {
  # best-effort default route iface
  ip route 2>/dev/null | awk '/default/ {print $5; exit}' || true
}

sys_ensure_apt() {
  if ! sys_cmd_exists apt-get; then
    ui_fail "apt-get не найден. Этот инструмент рассчитан на Debian/Ubuntu."
    return 1
  fi
  return 0
}

sys_apt_install() {
  local pkg="$1"
  sys_ensure_apt || return 1
  sys_need_sudo
  ui_info "apt-get update"
  sudo apt-get update -y
  ui_info "apt-get install: ${pkg}"
  sudo apt-get install -y "$pkg"
}

sys_backup_file() {
  local f="$1"
  if [[ -e "$f" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    sudo cp -a "$f" "${f}.bak-${ts}"
    ui_ok "Бэкап: ${f}.bak-${ts}"
  fi
}

sys_detect_ssh_unit() {
  # чаще всего ssh, иногда sshd
  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then echo "ssh"; return; fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then echo "sshd"; return; fi
  echo "ssh"
}

sys_detect_ssh_port() {
  local cfg="/etc/ssh/sshd_config"
  local port="22"
  if [[ -r "$cfg" ]]; then
    local p
    p="$(grep -E '^\s*Port\s+[0-9]+' "$cfg" | awk '{print $2}' | tail -n 1 || true)"
    [[ -n "$p" ]] && port="$p"
  fi
  echo "$port"
}
