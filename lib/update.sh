#!/usr/bin/env bash
set -euo pipefail

sys_tools_restart_now() {
  local root_dir="$1"

  ui_info "Применяю обновления: делаю перезапуск sys-tools..."

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

sys_tools_auto_update_on_start() {
  local root_dir="$1"
  local dirty="" local_rev="" remote_rev="" base_rev=""

  [[ "${SYS_TOOLS_AUTO_UPDATE:-1}" == "0" ]] && return 0
  [[ -d "${root_dir}/.git" ]] || return 0
  sys_cmd_exists git || return 0

  dirty="$(cd "$root_dir" && git status --porcelain 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    ui_warn "Auto-update: есть локальные изменения, пропускаю автообновление."
    return 0
  fi

  if ! (cd "$root_dir" && git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1); then
    ui_warn "Auto-update: для текущей ветки не настроен upstream, пропускаю."
    return 0
  fi

  ui_info "Auto-update: проверяю обновления..."
  if ! (cd "$root_dir" && git fetch --quiet --prune); then
    ui_warn "Auto-update: не удалось получить обновления, продолжаю без них."
    return 0
  fi

  local_rev="$(cd "$root_dir" && git rev-parse @ 2>/dev/null || true)"
  remote_rev="$(cd "$root_dir" && git rev-parse @{u} 2>/dev/null || true)"
  base_rev="$(cd "$root_dir" && git merge-base @ @{u} 2>/dev/null || true)"

  if [[ -z "$local_rev" || -z "$remote_rev" || -z "$base_rev" ]]; then
    ui_warn "Auto-update: не удалось определить состояние ветки, продолжаю без обновления."
    return 0
  fi

  # behind: локальная ветка отстаёт, можно безопасно делать pull --rebase
  if [[ "$local_rev" == "$base_rev" && "$local_rev" != "$remote_rev" ]]; then
    ui_info "Auto-update: найдены обновления, применяю..."
    if (cd "$root_dir" && git pull --rebase); then
      sys_tools_post_update_fixups "$root_dir"
      ui_ok "Auto-update: обновление применено, перезапуск."
      sys_tools_restart_now "$root_dir"
    fi
    ui_warn "Auto-update: git pull не выполнен. Можно обновить вручную через пункт 8."
    return 0
  fi

  if [[ "$local_rev" != "$remote_rev" && "$remote_rev" != "$base_rev" ]]; then
    ui_warn "Auto-update: ветка разошлась с upstream, пропускаю автообновление."
  fi
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
