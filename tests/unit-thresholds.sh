#!/usr/bin/env bash
# Юнит-тесты логики времени и порогов — БЕЗ сети, без запуска Claude и без рабочей машины.
#
# Функции берутся в режиме библиотеки (CLAUDE_GUARD_SOURCE_ONLY=1): скрипт только
# определяет функции и выходит. Выходной IP подставляется через CLAUDE_GUARD_EXIT_IP,
# логи Claude Desktop — в песочнице. Проверяются сами пороги: какая жалоба считается
# «про этот выход», какая поглощается, когда запоминается плохой IP.
#
# Запуск: ./tests/unit-thresholds.sh        (код выхода = число провалов)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/claude-guard-unit.XXXXXX")"
trap 'rm -rf "$SB"' EXIT

export CLAUDE_GUARD_STATE="$SB/state"
export CLAUDE_GUARD_LOGS_DIR="$SB/logs"
export CLAUDE_GUARD_EXIT_IP="203.0.113.10"   # никаких сетевых проб
export CLAUDE_GUARD_SOURCE_ONLY=1
mkdir -p "$SB/logs" "$SB/state"

# shellcheck disable=SC1090
. "$ROOT/linux/bin/claude-guard"   # режим библиотеки: только определения функций
CLAUDE_GUARD_SOURCE_ONLY=""

fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s%s\n' "$1" "${2:+ ($2)}"; fails=$((fails + 1)); }

ok() { # ok "название" условие-команда...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}
nonok() { # nonok "название" команда...    — ожидаем отказ (ненулевой код)
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$name" "не отказал"; else pass "$name"; fi
}

ts_ago() { date -d "@$(( $(date +%s) - $1 ))" '+%Y-%m-%d %H:%M:%S'; }
log_region() { # log_region <файл> <секунд назад>
  local f="$1" ago="$2"
  printf '%s [error] oauth failed: region_unavailable\n' "$(ts_ago "$ago")" >"$CLAUDE_GUARD_LOGS_DIR/$f"
}
log_403() { # log_403 <файл> <секунд назад> <сколько строк>
  local f="$1" ago="$2" n="${3:-1}" i
  : >"$CLAUDE_GUARD_LOGS_DIR/$f"
  for ((i = 0; i < n; i++)); do
    printf '%s [error] Claude.ai API returned 403\n' "$(ts_ago "$ago")" >>"$CLAUDE_GUARD_LOGS_DIR/$f"
  done
}
reset_state() { rm -f "$WEB_BLOCK_FILE" "$CLAUDE_GUARD_LOGS_DIR"/*.log; }

echo "=== время: разбор метки и «сейчас» ==="
log_region main.log 0
newest="$(newest_region_ts)"
now="$(date +%s)"
[ -n "$newest" ] && [ "$newest" -gt 0 ] && [ $((now - newest)) -le 3 ] \
  && pass "метка «сейчас» читается верно (нет сдвига часового пояса)" \
  || fail "метка «сейчас»" "newest=$newest now=$now разница=$((now - newest))"

log_region main.log 10800
newest="$(newest_region_ts)"; now="$(date +%s)"
diff=$((now - newest - 10800)); [ "${diff#-}" -le 3 ] \
  && pass "метка 3 часа назад читается верно (разница ${diff}s)" \
  || fail "метка 3 часа назад" "разница $diff"

echo
echo "=== свежая жалоба (порог REGION_FRESH=$REGION_FRESH) ==="
reset_state; log_region main.log 30
nonok "выход отклонён → отказ" check_anthropic_verdict full
ok "IP записан в память плохих выходов" blocked_ip_recorded "$CLAUDE_GUARD_EXIT_IP"

reset_state; log_region main.log $((REGION_FRESH - 10))
nonok "на границе свежести (минус 10 с) → отказ" check_anthropic_verdict full
ok "на границе свежести IP ещё запоминается" blocked_ip_recorded "$CLAUDE_GUARD_EXIT_IP"

# ВАЖНО про семантику: жалоба в окне свежести помечает выход плохим и блокирует запуск,
# а жалоба 120–900 с — только предупреждение («есть след»). Иначе после смены узла страж
# отказывал бы ещё четверть часа на исправном выходе; защита в этом случае держится на
# памяти плохих IP, а не на окне времени.
reset_state; log_region main.log $((REGION_FRESH + 10))
ok "чуть старее свежести → пропуск (жалоба не про этот выход, только след)" check_anthropic_verdict full
msg="$(check_anthropic_verdict full 2>&1)"
case "$msg" in
  *"есть след"*) pass "в окне STALE печатается предупреждение о следе";;
  *) fail "нет предупреждения о следе" "$msg";;
esac
if blocked_ip_recorded "$CLAUDE_GUARD_EXIT_IP"; then
  fail "поздняя жалоба не должна помечать текущий IP" "IP помечен"
else pass "поздняя жалоба не помечает текущий IP"; fi

echo
echo "=== окно STALE ($REGION_STALE с) ==="
reset_state; log_region main.log $((REGION_STALE - 60))
ok "жалоба в окне STALE → пропуск с предупреждением" check_anthropic_verdict full
reset_state; log_region main.log $((REGION_STALE + 60))
msg="$(check_anthropic_verdict full 2>&1)"
ok "жалоба старше окна → пропуск (поглощается)" check_anthropic_verdict full
case "$msg" in
  *"есть след"*) fail "жалоба старше окна не должна даже упоминаться" "$msg";;
  *) pass "жалоба старше окна не упоминается в выводе";;
esac
if blocked_ip_recorded "$CLAUDE_GUARD_EXIT_IP"; then
  fail "старая жалоба не должна помечать IP" "IP помечен"
else pass "старая жалоба не помечает IP"; fi

echo
echo "=== память плохих выходов работает и без логов ==="
reset_state; log_region main.log 30
nonok "свежая жалоба: отказ" check_anthropic_verdict full
rm -f "$CLAUDE_GUARD_LOGS_DIR"/main.log          # логи Desktop очищены (ротация/перезапуск)
nonok "отказ сохраняется по памяти IP, даже когда логов уже нет" check_anthropic_verdict full
rm -f "$WEB_BLOCK_FILE"
ok "сброс памяти (--reset-web-block) возвращает пропуск" check_anthropic_verdict full

echo
echo "=== будущая метка (сбитые часы) — fail-closed ==="
reset_state
printf '%s [error] region_unavailable\n' "$(date -d "@$(( $(date +%s) + 300 ))" '+%Y-%m-%d %H:%M:%S')" >"$CLAUDE_GUARD_LOGS_DIR/main.log"
nonok "метка из будущего → отказ, а не пропуск" check_anthropic_verdict full

echo
echo "=== слабый сигнал 403 (порог API403_MIN=$API403_MIN за API403_FRESH=$API403_FRESH с) ==="
reset_state; log_403 main.log 60 2
msg="$(check_anthropic_verdict full 2>&1)"
out=$?
[ "$out" -eq 0 ] && pass "серия 403 не блокирует (только предупреждение)" || fail "403 не должен блокировать" "код $out"
case "$msg" in *403*) pass "серия 403 попадает в сообщение";; *) fail "серия 403 не упомянута" "$msg";; esac

reset_state; log_403 main.log 60 1
msg="$(check_anthropic_verdict full 2>&1)"
case "$msg" in *403*) fail "одиночный 403 не должен считаться сигналом" "$msg";; *) pass "одиночный 403 игнорируется";; esac

reset_state; log_403 main.log $((API403_FRESH + 60)) 3
msg="$(check_anthropic_verdict full 2>&1)"
case "$msg" in *403*) fail "старые 403 не должны считаться сигналом" "$msg";; *) pass "старые 403 игнорируются";; esac

echo
echo "=== режим CLI: регион не проверяется ==="
reset_state; log_region main.log 30
ok "cli-режим пропускает даже при свежей жалобе" check_anthropic_verdict cli

echo
echo "=== память плохих выходов ==="
reset_state
ok "выход не помечен по умолчанию" bash -c "! blocked_ip_recorded 198.51.100.7"
record_blocked_ip 198.51.100.7
ok "record_blocked_ip помечает выход" blocked_ip_recorded 198.51.100.7
record_blocked_ip 198.51.100.7
[ "$(grep -c '^198.51.100.7 ' "$WEB_BLOCK_FILE")" = "1" ] \
  && pass "повторная запись не дублируется" || fail "повторная запись продублирована"

echo
if [ "$fails" = 0 ]; then echo "ИТОГ: все проверки пройдены"; else echo "ИТОГ: провалов $fails"; fi
exit "$fails"
