#!/usr/bin/env bash
set -euo pipefail

rw_update_stack() {
  local dir="$1"
  local title="$2"

  ui_h1 "RemnaWave — обновление: ${title}"
  if [[ ! -d "$dir" ]]; then
    ui_fail "Директория не найдена: $dir"
    ui_pause
    return 1
  fi

  ui_info "Директория: $dir"
  ui_confirm "Выполнить docker compose pull/down/up -d ?" "Y" || { ui_info "Отменено."; ui_pause; return 0; }

  ( cd "$dir" && docker compose pull )
  ( cd "$dir" && docker compose down )
  ( cd "$dir" && docker compose up -d )

  ui_ok "Обновлено: ${title}"
  ui_info "Показать логи сейчас?"
  if ui_confirm "docker compose logs -f ?" "N"; then
    ( cd "$dir" && docker compose logs -f )
  else
    ui_pause
  fi
}

rw_update_panel()   { rw_update_stack "/opt/remnawave" "Remnawave Panel"; }
rw_update_node()    { rw_update_stack "/opt/remnanode" "Remnawave Node"; }
rw_update_subpage() { rw_update_stack "/opt/remnawave/subscription" "Subscription Page"; }

plugin_remnawave_menu() {
  while true; do
    ui_clear
    ui_h1 "Меню: RemnaWave обновление"
    echo "1) Обновить Panel (/opt/remnawave)"
    echo "2) Обновить Node  (/opt/remnanode)"
    echo "3) Обновить Subpage (/opt/remnawave/subscription)"
    echo "0) Назад"
    echo
    read -rp "Выбор: " c || true
    case "${c:-}" in
      1) rw_update_panel ;;
      2) rw_update_node ;;
      3) rw_update_subpage ;;
      0) return 0 ;;
      *) ui_warn "Неверный выбор."; ui_pause ;;
    esac
  done
}
