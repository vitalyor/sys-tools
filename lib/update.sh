#!/usr/bin/env bash
set -euo pipefail

sys_tools_restart_now() {
  local root_dir="$1"

  ui_info "Применяю обновления: делаю перезапуск sys-tools..."
  ui_pause

  # Сначала пытаемся перезапуститься тем же entrypoint, которым запустились (если передан из toolbox.sh)
  if [[ -n "${SYS_TOOLS_ENTRY:-}" && -f "${SYS_TOOLS_ENTRY}" ]]; then
    exec bash "${SYS_TOOLS_ENTRY}"
  fi

  # Фолбэк — прямой запуск toolbox.sh
  exec bash "${root_dir}/toolbox.sh"
}

sys_tools_post_update_fixups() {
  local root_dir="$1"

  # После pull у тебя может слетать +x, а sys-tools запускается как исполняемый файл через симлинк
  sudo chmod +x "${root_dir}/toolbox.sh" 2>/dev/null || true

  # Можно добавить сюда любые будущие fixups (например миграции структуры)
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
    ui_warn "Есть локальные изменения. Обычный git pull --rebase не выполнится."
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
        ui_info "Шаг 1/3: stash..."
        ( cd "$root_dir" && git stash push -m "sys-tools auto-stash before update" )
        ui_info "Шаг 2/3: pull --rebase..."
        ( cd "$root_dir" && git pull --rebase )
        ui_info "Шаг 3/3: stash pop..."
        ( cd "$root_dir" && git stash pop ) || true

        sys_tools_post_update_fixups "$root_dir"
        ui_ok "Обновлено. (Если были конфликты — проверь git status.)"
        sys_tools_restart_now "$root_dir"
        ;;
      2)
        ui_warn "Это удалит ВСЕ локальные изменения и неотслеживаемые файлы в ${root_dir}."
        ui_confirm "Точно продолжить?" "N" || { ui_info "Отменено."; ui_pause; return 0; }

        ui_info "Шаг 1/3: fetch..."
        ( cd "$root_dir" && git fetch --all )
        ui_info "Шаг 2/3: reset --hard origin/main..."
        ( cd "$root_dir" && git reset --hard origin/main )
        ui_info "Шаг 3/3: clean -fd..."
        ( cd "$root_dir" && git clean -fd )

        ui_info "pull --rebase..."
        ( cd "$root_dir" && git pull --rebase )

        sys_tools_post_update_fixups "$root_dir"
        ui_ok "Сброшено и обновлено."
        sys_tools_restart_now "$root_dir"
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
    sys_tools_post_update_fixups "$root_dir"
    ui_ok "Обновлено."
    sys_tools_restart_now "$root_dir"
  else
    ui_info "Отменено."
    ui_pause
  fi
}