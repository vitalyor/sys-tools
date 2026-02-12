#!/usr/bin/env bash
set -euo pipefail

sys_tools_restart_now() {
  local root_dir="$1"
  ui_info "Перезапускаю sys-tools, чтобы применились обновления..."
  ui_pause

  if [[ -n "${SYS_TOOLS_ENTRY:-}" && -f "${SYS_TOOLS_ENTRY}" ]]; then
    exec bash "${SYS_TOOLS_ENTRY}"
  fi

  exec bash "${root_dir}/toolbox.sh"
}

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

  # Проверяем грязное дерево
  local dirty=""
  dirty="$(cd "$root_dir" && git status --porcelain || true)"

  if [[ -n "$dirty" ]]; then
    ui_warn "Есть локальные изменения. git pull --rebase не выполнится."
    echo
    ui_info "Варианты:"
    echo "1) Stash изменения → pull --rebase → stash pop (сохранить изменения)"
    echo "2) Сбросить изменения (reset --hard + clean -fd) → pull (УДАЛИТ всё локальное)"
    echo "0) Отмена"
    echo
    local c
    read -rp "Выбор: " c || true

    case "${c:-}" in
      1)
        ui_info "Делаю stash..."
        ( cd "$root_dir" && git stash push -m "sys-tools auto-stash before update" )
        ui_info "Делаю pull --rebase..."
        ( cd "$root_dir" && git pull --rebase )
        ui_info "Возвращаю stash..."
        ( cd "$root_dir" && git stash pop ) || true
        ui_ok "Готово (если были конфликты — проверь git status)."
        ui_pause
        return 0
        ;;
      2)
        ui_warn "Это удалит ВСЕ локальные изменения и неотслеживаемые файлы в ${root_dir}."
        ui_confirm "Точно продолжить?" "N" || { ui_info "Отменено."; ui_pause; return 0; }
        ( cd "$root_dir" && git fetch --all )
        ( cd "$root_dir" && git reset --hard origin/main )
        ( cd "$root_dir" && git clean -fd )
        ( cd "$root_dir" && git pull --rebase )
        ui_ok "Сброшено и обновлено."
        sys_tools_restart_now "$root_dir"
        ui_pause
        return 0
        ;;
      0)
        ui_info "Отменено."
        ui_pause
        return 0
        ;;
      *)
        ui_warn "Неверный выбор."
        ui_pause
        return 0
        ;;
    esac
  fi

  if ui_confirm "Сделать git pull (обновить)?" "Y"; then
    ( cd "$root_dir" && git pull --rebase )
    ui_ok "Обновлено."
  else
    ui_info "Отменено."
  fi
  ui_pause
}
