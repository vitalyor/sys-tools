#!/usr/bin/env bash
set -euo pipefail

# Корректно определяем ROOT_DIR даже если скрипт запущен через symlink (/usr/local/bin/sys-tools)
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
ROOT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

SYS_TOOLS_ENTRY="$SOURCE"
export SYS_TOOLS_ENTRY

# libs
# shellcheck source=lib/ui.sh
source "${ROOT_DIR}/lib/ui.sh"
# shellcheck source=lib/system.sh
source "${ROOT_DIR}/lib/system.sh"
# shellcheck source=lib/update.sh
source "${ROOT_DIR}/lib/update.sh"

# plugins
# shellcheck source=plugins/fail2ban.sh
source "${ROOT_DIR}/plugins/fail2ban.sh"
# shellcheck source=plugins/vnstat.sh
source "${ROOT_DIR}/plugins/vnstat.sh"
# shellcheck source=plugins/firewall.sh
source "${ROOT_DIR}/plugins/firewall.sh"
# shellcheck source=plugins/remnawave.sh
source "${ROOT_DIR}/plugins/remnawave.sh"
# shellcheck source=plugins/remnanode.sh
source "${ROOT_DIR}/plugins/remnanode.sh"

TOOL_NAME="sys-tools"
TOOL_VERSION="$(cat "${ROOT_DIR}/VERSION" 2>/dev/null || echo "unknown")"

about() {
  ui_h1 "О программе"
  ui_kv "Название" "${TOOL_NAME}"
  ui_kv "Версия" "${TOOL_VERSION}"
  ui_kv "Хост" "$(hostname)"
  ui_kv "ОС" "$(sys_os_pretty)"
  ui_kv "Дата" "$(date)"
  ui_kv "Public IP" "$(sys_public_ip)"
  echo
  ui_info "Команда запуска: sys-tools"
  ui_info "Путь: ${ROOT_DIR}"
  ui_pause
}

main_menu() {
  while true; do
    ui_clear
    ui_h1 "${TOOL_NAME} — v${TOOL_VERSION}"

    echo "1) Fail2ban (установка / настройка / отчёт)"
    echo "2) vnStat (учёт трафика / статистика)"
    echo "3) Firewall / Ports (UFW / слушающие порты / аудит ssh)"
    echo "4) RemnaWave (обновить panel/node/subpage)"
    echo "5) RemnaNode (Docker + Xray-core + DNS-check + Caddy selfsteal)"
    echo "8) Обновить sys-tools из репозитория"
    echo "9) О программе / версия / инфо о системе"
    echo "0) Выход"
    echo
    read -rp "Выбор: " c || true

    case "${c:-}" in
      1) plugin_fail2ban_menu ;;
      2) plugin_vnstat_menu ;;
      3) plugin_firewall_menu ;;
      4) plugin_remnawave_menu ;;
      5) plugin_remnanode_menu ;;
      8) sys_tools_update_menu "${ROOT_DIR}" ;;
      9) about ;;
      0) exit 0 ;;
      *) ui_warn "Неверный выбор."; ui_pause ;;
    esac
  done
}

main() {
  sys_need_bash
  main_menu
}

main "$@"
