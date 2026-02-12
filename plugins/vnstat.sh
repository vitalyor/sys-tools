#!/usr/bin/env bash
set -euo pipefail

vnstat_installed() { sys_cmd_exists vnstat; }

vnstat_version() {
  vnstat --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1 || echo "0.0"
}

vnstat_major() {
  vnstat_version | cut -d. -f1 | tr -cd '0-9' || echo "0"
}

vnstat_iface_exists() {
  local iface="$1"
  vnstat --iflist 2>/dev/null | tr ' ' '\n' | grep -xq "$iface"
}

vnstat_install() {
  ui_h1 "vnStat — установка"
  if vnstat_installed; then ui_ok "vnStat уже установлен."; ui_pause; return 0; fi
  sys_apt_install "vnstat"
  sudo systemctl enable --now vnstat >/dev/null 2>&1 || true
  ui_ok "vnStat установлен и сервис включён."
  ui_pause
}

vnstat_init_iface() {
  ui_h1 "vnStat — инициализация интерфейса"
  sys_need_sudo

  vnstat_installed || {
    ui_warn "vnStat не установлен."
    ui_confirm "Установить?" "Y" && vnstat_install || { ui_pause; return 0; }
  }

  local def_if
  def_if="$(sys_default_iface)"
  [[ -z "$def_if" ]] && def_if="eth0"

  ui_info "Сетевые интерфейсы:"
  ip -o link show | awk -F': ' '{print " - " $2}' | sed 's/@.*//' || true
  echo
  ui_info "Подсказка: интерфейс по default route:"
  ip route | awk '/default/ {print " - " $5; exit}' || true
  echo

  local iface
  iface="$(ui_input "Какой интерфейс учитывать в vnStat?" "$def_if")"

  local ver maj
  ver="$(vnstat_version)"
  maj="$(vnstat_major)"
  ui_info "Версия vnStat: ${ver}"

  sudo systemctl enable --now vnstat >/dev/null 2>&1 || true

  if vnstat_iface_exists "$iface"; then
    ui_ok "Интерфейс ${iface} уже есть в базе vnStat (ничего не добавляю)."
  else
    if [[ "$maj" =~ ^[0-9]+$ ]] && (( maj >= 2 )); then
      ui_info "Добавляю интерфейс (vnStat 2.x): vnstat --add -i ${iface}"
      sudo vnstat --add -i "$iface"
    else
      ui_info "Добавляю интерфейс (vnStat 1.x): vnstat -u -i ${iface}"
      sudo vnstat -u -i "$iface"
    fi
    ui_ok "Интерфейс добавлен: ${iface}"
  fi

  sudo systemctl restart vnstat >/dev/null 2>&1 || true

  ui_ok "Инициализация завершена."
  echo
  ui_info "Список интерфейсов vnStat:"
  vnstat --iflist 2>/dev/null || true
  echo
  ui_info "Oneline:"
  vnstat --oneline 2>/dev/null || true

  ui_pause
}

vnstat_stats() {
  ui_h1 "vnStat — статистика"
  vnstat_installed || { ui_warn "vnStat не установлен."; ui_pause; return 0; }

  echo "1) Сутки (-d)"
  echo "2) Месяц (-m)"
  echo "3) По часам (-h)"
  echo "4) По интерфейсам (vnstat --iflist)"
  echo "0) Назад"
  echo
  read -rp "Выбор: " c || true

  case "${c:-}" in
    1) vnstat -d || true ;;
    2) vnstat -m || true ;;
    3) vnstat -h || true ;;
    4) vnstat --iflist || true ;;
    0) return 0 ;;
    *) ui_warn "Неверный выбор." ;;
  esac
  ui_pause
}

plugin_vnstat_menu() {
  while true; do
    ui_clear
    ui_h1 "Меню: vnStat"
    echo "1) Установить vnStat"
    echo "2) Инициализировать интерфейс (важно!)"
    echo "3) Показать статистику"
    echo "0) Назад"
    echo
    read -rp "Выбор: " c || true
    case "${c:-}" in
      1) vnstat_install ;;
      2) vnstat_init_iface ;;
      3) vnstat_stats ;;
      0) return 0 ;;
      *) ui_warn "Неверный выбор."; ui_pause ;;
    esac
  done
}
