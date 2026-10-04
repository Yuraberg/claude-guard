#!/usr/bin/env bash
# E2E-тест установки Linux-ветки в изолированный HOME — режим --no-systemd
# (именно он используется в WSL, где systemd может быть недоступен).
#
# Проверяется: установщик ставит скрипты и обёртку, обёртка реально блокирует запуск
# при выходе РФ, снятие возвращает систему в исходное состояние. Рабочий HOME не трогается.
#
# Запуск: ./tests/linux-install-e2e.sh     (код выхода = число провалов)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/claude-guard-e2e.XXXXXX")"
trap 'rm -rf "$SB"' EXIT

export HOME="$SB/home"
mkdir -p "$HOME/.local/lib/node_modules/@anthropic-ai/claude-code/bin"
# «Настоящий» Claude Code — исполняемый ELF > 1 МБ (иначе обёртка обоснованно откажется)
cat /bin/ls >"$HOME/.local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
dd if=/dev/zero bs=1M count=2 status=none >>"$HOME/.local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
chmod 755 "$HOME/.local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"

fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s%s\n' "$1" "${2:+ ($2)}"; fails=$((fails + 1)); }
ok() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else fail "$n"; fi; }

echo "=== установка (--no-systemd, изолированный HOME) ==="
out="$("$ROOT/linux/install.sh" --no-systemd 2>&1)"
rc=$?
echo "$out" | sed 's/^/  | /'
case "$rc" in
  0) pass "установщик завершился успешно (код 0)";;
  1) if grep -q "самопроверка не прошла" <<<"$out"; then
       pass "установщик отработал (код 1: на этой машине нет VPN — ожидаемо)"
     else fail "установщик вернул 1 без объяснения" "$rc"; fi;;
  *) fail "установщик вернул неожиданный код" "$rc";;
esac

echo
echo "=== что установлено ==="
for f in claude claude-guard claude-desktop-guard claude-desktop-watchdog; do
  ok "в ~/.local/bin есть $f" test -x "$HOME/.local/bin/$f"
done
ok "обёртка claude указывает на страж" grep -q "claude-guard" "$HOME/.local/bin/claude"
ok "журнал стража создан" test -d "$HOME/.local/state/claude-guard"
ok "Claude Desktop закрыт страхом (.desktop переопределён)" \
   test -f "$HOME/.local/share/applications/com.anthropic.Claude.desktop"
ok "в .desktop не осталось прямого запуска приложения" \
   bash -c "! grep -qE '^Exec=(/usr/lib/claude-desktop|/usr/bin/claude-desktop)' '$HOME/.local/share/applications/com.anthropic.Claude.desktop' 2>/dev/null"
ok "systemd-службы НЕ поставлены (режим --no-systemd)" test ! -e "$HOME/.config/systemd/user/claude-desktop-tunnel-guard.service"

echo
echo "=== обёртка действительно защищает ==="
CLAUDE_GUARD_SIM=ru-exit "$HOME/.local/bin/claude" -p тест >/dev/null 2>&1
[ $? -eq 1 ] && pass "выход РФ: запуск через ~/.local/bin/claude отменён" || fail "выход РФ не заблокирован"
out="$(CLAUDE_GUARD_SIM=ru-exit "$HOME/.local/bin/claude" -p тест 2>&1)"
grep -q "ОТМЕНЁН\|ОТКАЗ" <<<"$out" && pass "сказано, что запуск отменён" || fail "нет сообщения об отмене" "$out"
CLAUDE_GUARD_SIM=no-tun "$HOME/.local/bin/claude" -p тест >/dev/null 2>&1
[ $? -eq 1 ] && pass "нет туннеля: запуск отменён" || fail "нет отказа без туннеля"
ok "диагностика --status работает из установленного места" \
   env -u CLAUDE_GUARD_SIM "$HOME/.local/bin/claude-guard" --status

echo
echo "=== снятие ==="
"$ROOT/linux/install.sh" --uninstall >/dev/null 2>&1
ok "снятие завершилось" test $? -eq 0
ok "страж снят из ~/.local/bin" test ! -e "$HOME/.local/bin/claude-guard"
ok "сторож снят" test ! -e "$HOME/.local/bin/claude-desktop-watchdog"
ok "переопределение .desktop снято" test ! -e "$HOME/.local/share/applications/com.anthropic.Claude.desktop"
ok "логи остались на месте (не удаляем молча)" test -d "$HOME/.local/state/claude-guard"

echo
if [ "$fails" = 0 ]; then echo "ИТОГ: все проверки пройдены"; else echo "ИТОГ: провалов $fails"; fi
exit "$fails"
