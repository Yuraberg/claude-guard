#!/usr/bin/env bash
# install.sh — установка claude-guard на этой машине. Идемпотентно, без вопросов.
#
#   ./install.sh              поставить / починить
#   ./install.sh --no-systemd без служб systemd (только обёртка + .desktop)
#   ./install.sh --uninstall  снять всё
#
# Что ставит: скрипт-страж и обёртку claude, сторож процесса, .desktop-переопределение
# для Claude Desktop (если он есть), systemd-службы для авто-старта и самолечения.
set -uo pipefail

SRC_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
APP_DIR="$HOME/.local/share/applications"
STATE_DIR="$HOME/.local/state/claude-guard"
USE_SYSTEMD=1
MODE="install"

for a in "$@"; do
  case "$a" in
    --no-systemd) USE_SYSTEMD=0 ;;
    --uninstall)  MODE="uninstall" ;;
    --help|-h) sed -n '2,10p' "$0"; exit 0 ;;
  esac
done

say() { printf '%s\n' "$*"; }
warn() { printf 'ВНИМАНИЕ: %s\n' "$*" >&2; }

# systemd пишем только если он обслуживает именно этот HOME (иначе — песочница/чужой дом)
systemd_ours() {
  [ "$USE_SYSTEMD" = "1" ] || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user show-environment >/dev/null 2>&1 || return 1
  local shome
  shome=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^HOME=//p')
  [ "$shome" = "$HOME" ]
}

detect_desktop_app() {
  local p
  for p in /usr/bin/claude-desktop /usr/lib/claude-desktop/claude-desktop \
           /opt/Claude/claude-desktop /opt/claude-desktop/claude-desktop; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

detect_desktop_entry() {
  local f
  for f in /usr/share/applications/com.anthropic.Claude.desktop \
           /usr/share/applications/claude-desktop.desktop \
           /usr/local/share/applications/com.anthropic.Claude.desktop; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

uninstall_all() {
  say "Снятие claude-guard"
  [ -x "$BIN_DIR/claude-guard" ] && "$BIN_DIR/claude-guard" --uninstall || true
  # ВАЖНО: systemctl --user не изолируется подменой HOME — он всегда один на пользователя.
  # Поэтому службы трогаем только если systemd обслуживает именно этот HOME (иначе это
  # чужой дом, например песочница тестов) — иначе снятие в песочнице гасит защиту на
  # рабочей машине.
  if systemd_ours; then
    systemctl --user disable --now claude-desktop-tunnel-guard.service 2>/dev/null || true
    systemctl --user disable --now claude-guard-heal.timer 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
  else
    say "  (systemd этого HOME не обслуживает — службы не трогаю)"
  fi
  rm -f "$UNIT_DIR/claude-desktop-tunnel-guard.service" "$UNIT_DIR/claude-guard-heal.service" "$UNIT_DIR/claude-guard-heal.timer"
  rm -f "$APP_DIR/com.anthropic.Claude.desktop"
  if [ -f /usr/share/applications/com.anthropic.Claude.desktop ]; then
    say "Системный .desktop на месте — запуск Desktop вернулся к обычному."
  fi
  rm -f "$BIN_DIR/claude-desktop-guard" "$BIN_DIR/claude-desktop-watchdog" "$BIN_DIR/claude-guard"
  say "Готово. Логи остались в $STATE_DIR"
  exit 0
}

[ "$MODE" = "uninstall" ] && uninstall_all

# ── проверки перед установкой ───────────────────────────────────────────────
say "=== 1/6 проверка окружения ==="
command -v curl >/dev/null 2>&1 || { warn "нет curl — он обязателен для проверки страны выхода"; exit 1; }
command -v ip   >/dev/null 2>&1 || warn "нет команды ip — проверка интерфейса будет ослаблена"
mkdir -p "$BIN_DIR" "$STATE_DIR" 2>/dev/null

# ── скрипты ────────────────────────────────────────────────────────────────
say "=== 2/6 установка скриптов в $BIN_DIR ==="
for f in claude-guard claude-desktop-guard claude-desktop-watchdog; do
  install -m 755 "$SRC_DIR/bin/$f" "$BIN_DIR/$f" || { warn "не удалось поставить $f"; exit 1; }
  say "  $BIN_DIR/$f"
done

# ── обёртка Claude Code ────────────────────────────────────────────────────
say "=== 3/6 обёртка Claude Code ==="
if ! "$BIN_DIR/claude-guard" --install; then
  warn "не удалось поставить обёртку (Claude Code не найден?) — остальное установлю"
fi

# ── .desktop для Claude Desktop ────────────────────────────────────────────
say "=== 4/6 Claude Desktop ==="
if detect_desktop_app >/dev/null; then
  mkdir -p "$APP_DIR"
  ENTRY="$(detect_desktop_entry || true)"
  NAME="Claude"; ICON="claude-desktop"; WMCLASS="com.anthropic.Claude"; MIME="x-scheme-handler/claude;"
  if [ -n "$ENTRY" ]; then
    NAME=$(sed -n 's/^Name=//p' "$ENTRY" | head -1); NAME=${NAME:-Claude}
    ICON=$(sed -n 's/^Icon=//p' "$ENTRY" | head -1); ICON=${ICON:-claude-desktop}
    WMCLASS=$(sed -n 's/^StartupWMClass=//p' "$ENTRY" | head -1); WMCLASS=${WMCLASS:-com.anthropic.Claude}
    MIME=$(sed -n 's/^MimeType=//p' "$ENTRY" | head -1); MIME=${MIME:-x-scheme-handler/claude;}
    say "  беру поля из $ENTRY"
  fi
  cat > "$APP_DIR/com.anthropic.Claude.desktop" <<EOF
[Desktop Entry]
Name=$NAME
Comment=Desktop application (запуск только с VPN)
GenericName=AI Assistant
Keywords=AI;Chat;Assistant;Claude;Code;LLM;
Exec=$BIN_DIR/claude-desktop-guard %U
Icon=$ICON
Type=Application
StartupNotify=true
StartupWMClass=$WMCLASS
SingleMainWindow=true
Categories=Utility;Development;
MimeType=$MIME

[Desktop Action NewChat]
Name=New chat
Exec=$BIN_DIR/claude-desktop-guard claude://claude.ai/new

[Desktop Action NewCode]
Name=New Claude Code session
Exec=$BIN_DIR/claude-desktop-guard claude://code/new
EOF
  chmod 644 "$APP_DIR/com.anthropic.Claude.desktop"
  say "  $APP_DIR/com.anthropic.Claude.desktop → запуск через страж"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APP_DIR" 2>/dev/null || true
  command -v desktop-file-validate >/dev/null 2>&1 && desktop-file-validate "$APP_DIR/com.anthropic.Claude.desktop" >/dev/null 2>&1 && say "  файл валиден" || true
else
  say "  Claude Desktop не найден — пропускаю (только CLI-защита)"
fi

# ── systemd ────────────────────────────────────────────────────────────────
say "=== 5/6 службы ==="
if systemd_ours; then
  mkdir -p "$UNIT_DIR"
  install -m 644 "$SRC_DIR/systemd/claude-desktop-tunnel-guard.service" "$UNIT_DIR/"
  install -m 644 "$SRC_DIR/systemd/claude-guard-heal.service" "$UNIT_DIR/"
  install -m 644 "$SRC_DIR/systemd/claude-guard-heal.timer" "$UNIT_DIR/"
  systemctl --user daemon-reload
  systemctl --user enable --now claude-desktop-tunnel-guard.service
  systemctl --user enable --now claude-guard-heal.timer
  say "  claude-desktop-tunnel-guard.service: $(systemctl --user is-active claude-desktop-tunnel-guard.service)"
  say "  claude-guard-heal.timer: $(systemctl --user is-active claude-guard-heal.timer)"
else
  warn "systemd --user недоступен для этого HOME — службы не ставлю."
  warn "Запусти сторож вручную (например, в автозапуске WM): $BIN_DIR/claude-desktop-watchdog"
fi

# ── проверка ───────────────────────────────────────────────────────────────
say "=== 6/6 проверка ==="
"$BIN_DIR/claude-guard" --doctor || true
say
"$BIN_DIR/claude-guard" --self-test
RC=$?
say
if [ $RC -eq 0 ]; then
  say "УСТАНОВЛЕНО. Обёртка: $BIN_DIR/claude → страж."
  say "Проверь руками: $BIN_DIR/claude --version && $BIN_DIR/claude-guard --status"
else
  warn "самопроверка не прошла — смотри вывод выше (вероятно, VPN не поднят)"
fi
exit $RC
