#!/usr/bin/env bash
set -euo pipefail

sys_tools_update_menu() {
  local root_dir="$1"

  ui_h1 "Обновление sys-tools"
  if [[ ! -d "${root_dir}/.git" ]]; then
    ui_warn "Это не git-клон (нет .git). Обновление через git pull недоступно."
    ui_info "Решение: установить через install.sh, чтобы был git."
    ui_pause
    return 0
  fi

  ui_info "Текущая директория: ${root_dir}"
  if ui_confirm "Сделать git pull (обновить)?" "Y"; then
    sys_need_sudo
    ( cd "$root_dir" && git pull --rebase )
    ui_ok "Обновлено."
  else
    ui_info "Отменено."
  fi
  ui_pause
}
