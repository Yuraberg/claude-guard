#!/usr/bin/env bash
# Проверка Linux-ветки комплекта claude-guard — в песочнице, рабочую систему не трогает.
# Запуск: ./tests/bash-tests.sh        (код выхода = число провалов)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/linux/bin"
SB="$(mktemp -d "${TMPDIR:-/tmp}/claude-guard-tests.XXXXXX")"
trap 'rm -rf "$SB"' EXIT

# Всё состояние — в песочницу: реальные логи/память стража не затрагиваются
export CLAUDE_GUARD_STATE="$SB/state"
export CLAUDE_GUARD_LOGS_DIR="$SB/logs"
export CLAUDE_GUARD_WRAPPER="$SB/bin/claude"
mkdir -p "$SB/logs" "$SB/bin"

fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s%s\n' "$1" "${2:+ ($2)}"; fails=$((fails + 1)); }

check() { # check "название" "ожидаемый код" команда...
  local name="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  [ "$rc" = "$want" ] && pass "$name" || fail "$name" "код $rc, ожидался $want"
}

check_net() { # как check, но с повторами: сетевая проба бывает капризной
  local name="$1" want="$2"; shift 2
  local i rc
  for i in 1 2 3; do
    "$@" >/dev/null 2>&1; rc=$?
    [ "$rc" = "$want" ] && break
    sleep 4
  done
  [ "$rc" = "$want" ] && pass "$name" || fail "$name" "код $rc, ожидался $want"
}

check_out() { # check_out "название" "шаблон" команда...
  local name="$1" pat="$2"; shift 2
  local out
  out="$("$@" 2>&1)"
  if grep -qE "$pat" <<<"$out"; then pass "$name"; else fail "$name" "нет «$pat» в выводе"; fi
}

fresh_region_log() {
  printf '%s [error] oauth failed: region_unavailable\n' "$(date '+%Y-%m-%d %H:%M:%S')" >"$SB/logs/main.log"
}

echo "=== синтаксис ==="
for f in "$BIN"/* "$ROOT/linux/install.sh"; do
  if bash -n "$f" 2>/dev/null; then pass "bash -n $(basename "$f")"; else fail "bash -n $f"; fi
done

echo
echo "=== страж: базовые проверки ==="
check_net "--self-test (6 симуляций)" 0 "$BIN/claude-guard" --self-test
check_net "--check при живом туннеле (пробы через VPN)" 0 "$BIN/claude-guard" --check
check_net "--check-cli" 0 "$BIN/claude-guard" --check-cli
check "--doctor" 0 "$BIN/claude-guard" --doctor
check_net "--status" 0 "$BIN/claude-guard" --status

for sim in no-tun ru-exit timeout region ipv6-leak; do
  CLAUDE_GUARD_SIM="$sim" "$BIN/claude-guard" -p тест >/dev/null 2>&1
  [ $? = 1 ] && pass "симуляция $sim: запуск отменён" || fail "симуляция $sim: нет отказа"
done

echo
echo "=== 4-я проверка: вердикт Anthropic ==="
fresh_region_log
check "свежая жалоба: --check отказывает" 1 "$BIN/claude-guard" --check
check_net "свежая жалоба: --check-cli пропускает (важен только api.anthropic.com)" 0 "$BIN/claude-guard" --check-cli
check_out "путь запуска: совет «смени узел»" 'смени узел' "$BIN/claude-guard" -p тест
check "путь запуска: отказ (код 1)" 1 "$BIN/claude-guard" -p тест
grep -q 'launch BLOCKED reason=anthropic' "$CLAUDE_GUARD_STATE/guard.log" \
  && pass "журнал: launch BLOCKED reason=anthropic" || fail "журнал: причина не записана"
[ -s "$CLAUDE_GUARD_STATE/web-blocked-ips" ] \
  && pass "выход записан в память плохих выходов" || fail "выход не записан"

printf '%s [error] region_unavailable\n' "$(date -d '3 hours ago' '+%Y-%m-%d %H:%M:%S')" >"$SB/logs/main.log"
rm -f "$CLAUDE_GUARD_STATE/web-blocked-ips"
check_net "старая жалоба (>15 мин): --check пропускает" 0 "$BIN/claude-guard" --check

check "--mark-blocked (без аргумента — текущий выход)" 0 "$BIN/claude-guard" --mark-blocked
check "помеченный текущий выход: --check отказывает" 1 "$BIN/claude-guard" --check
check "--reset-web-block" 0 "$BIN/claude-guard" --reset-web-block
check_net "после сброса: --check пропускает" 0 "$BIN/claude-guard" --check
check_out "--status показывает вердикт Anthropic" 'вердикт Anthropic' "$BIN/claude-guard" --status

echo
echo "=== пробники выхода: цепочка без лимитов ==="
BROKEN='http://127.0.0.1:9/x'
check_net "живой прогон: --check проходит" 0 "$BIN/claude-guard" --check
grep -q 'src=trace' "$CLAUDE_GUARD_STATE/guard.log" \
  && pass "журнал: источник пробы = trace (не ipinfo с лимитами)" || fail "журнал: источник пробы не виден"
# Запасной пробник проверяем герметично: тело ответа берём из каталога-фикстуры
# (тестовый шов PROBE_FIXTURE) — важно именно то, что цепочка падает на следующий
# пробник, а не наличие сети в момент прогона.
mkdir -p "$SB/fixture"
printf 'fl=test\nip=198.51.100.7\nts=1\nloc=US\n' >"$SB/fixture/trace"
check_net "основной пробник недоступен → сработал запасной" 0 \
  env CLAUDE_GUARD_PROBE_FIXTURE="$SB/fixture" CLAUDE_GUARD_PROBE_PRIMARY="$BROKEN" \
      "$BIN/claude-guard" --check
check "фикстура: нет файла пробника → «не ответил» → отказ" 1 \
  env CLAUDE_GUARD_PROBE_FIXTURE="$SB/empty-fixture" CLAUDE_GUARD_PROBE_PRIMARY="$BROKEN" \
      "$BIN/claude-guard" --check
check "ни один пробник не отвечает → отказ (fail-closed)" 1 \
  env CLAUDE_GUARD_PROBE_PRIMARY="$BROKEN" CLAUDE_GUARD_PROBE_SECONDARY="$BROKEN" \
      CLAUDE_GUARD_PROBE_JSON="$BROKEN" "$BIN/claude-guard" --check
grep -q 'reason=no-answer' "$CLAUDE_GUARD_STATE/guard.log" \
  && pass "журнал: причина = no-answer (а не «нет туннеля»)" || fail "журнал: причина не no-answer"
check_out "текст отказа говорит о пробе, а не о VPN" 'ни один пробник выхода не ответил' \
  env CLAUDE_GUARD_PROBE_PRIMARY="$BROKEN" CLAUDE_GUARD_PROBE_SECONDARY="$BROKEN" \
      CLAUDE_GUARD_PROBE_JSON="$BROKEN" "$BIN/claude-guard" --check

FAKE="$SB/fakebin"; mkdir -p "$FAKE"; rm -f "$SB/calls"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/calls"\n' "$SB" >"$FAKE/notify-send"
chmod +x "$FAKE/notify-send"
env PATH="$FAKE:$PATH" WAYLAND_DISPLAY=x DISPLAY= CLAUDE_GUARD_QUIET=1 \
    CLAUDE_GUARD_PROBE_PRIMARY="$BROKEN" CLAUDE_GUARD_PROBE_SECONDARY="$BROKEN" \
    CLAUDE_GUARD_PROBE_JSON="$BROKEN" "$BIN/claude-guard" --check >/dev/null 2>&1
[ ! -s "$SB/calls" ] && pass "QUIET: фоновая проверка не шлёт уведомлений" \
                     || fail "QUIET: уведомление всё равно ушло" "$(cat "$SB/calls")"
env PATH="$FAKE:$PATH" WAYLAND_DISPLAY=x DISPLAY= \
    CLAUDE_GUARD_PROBE_PRIMARY="$BROKEN" CLAUDE_GUARD_PROBE_SECONDARY="$BROKEN" \
    CLAUDE_GUARD_PROBE_JSON="$BROKEN" "$BIN/claude-guard" --check >/dev/null 2>&1
if grep -q 'проба выхода не ответила' "$SB/calls" 2>/dev/null; then
  pass "ручной запуск: уведомление с фактической причиной"
else
  fail "ручной запуск: текст уведомления не про причину" "$(head -1 "$SB/calls" 2>/dev/null)"
fi

env WATCH_DRY=1 WATCH_PROBE_EVERY=1 \
    CLAUDE_GUARD_PROBE_PRIMARY="$BROKEN" CLAUDE_GUARD_PROBE_SECONDARY="$BROKEN" \
    CLAUDE_GUARD_PROBE_JSON="$BROKEN" "$BIN/claude-desktop-watchdog" --once --dry-run >/dev/null 2>&1
grep -q 'guard check failed .* reason=no-answer' "$CLAUDE_GUARD_STATE/watchdog.log" \
  && pass "сторож: назвал причину провала (no-answer)" || fail "сторож: причина не записана"

echo
echo "=== сторож (dry-run, ничего не гасит) ==="
fresh_region_log
check_out "свежая жалоба → DRY-RUN region" 'DRY-RUN \(region\)' \
  env WATCH_DRY=1 "$BIN/claude-desktop-watchdog" --once --dry-run
check_out "симуляция падения VPN → DRY-RUN" 'DRY-RUN' \
  env WATCH_DRY=1 WATCH_FORCE_DOWN=1 "$BIN/claude-desktop-watchdog" --once --dry-run
printf '%s [error] region_unavailable\n' "$(date -d '3 hours ago' '+%Y-%m-%d %H:%M:%S')" >"$SB/logs/main.log"
rm -f "$CLAUDE_GUARD_STATE/watch-last-region-ts"
out="$(env WATCH_DRY=1 "$BIN/claude-desktop-watchdog" --once --dry-run 2>&1)"
grep -q 'DRY-RUN (region)' <<<"$out" \
  && fail "старая жалоба: сторож не должен реагировать" || pass "старая жалоба: сторож молчит (поглотил)"

echo
if [ "$fails" = 0 ]; then echo "ИТОГ: все проверки пройдены"; else echo "ИТОГ: провалов $fails"; fi
exit "$fails"
