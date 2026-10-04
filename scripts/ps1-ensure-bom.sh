#!/usr/bin/env bash
# Проставляет UTF-8 BOM во всех .ps1 комплекта, где он нужен.
#
# Зачем: Windows PowerShell 5.1 читает .ps1 без BOM как ANSI (кодировка системы), поэтому
# кириллица в тексте превращается в мусор, а если испорченные байты попадают в синтаксис —
# файл вообще не парсится («Unexpected token ':' in expression»). PowerShell 7 читает UTF-8
# и без BOM, поэтому поломка видна ТОЛЬКО на настоящей Windows — что и случилось в CI.
#
# Файлы без не-ASCII символов BOM не получают (чистый ASCII одинаков в любой кодировке).
# Скрипт идемпотентен: повторный запуск ничего не меняет.
#
#   ./scripts/ps1-ensure-bom.sh          проверить и починить
#   ./scripts/ps1-ensure-bom.sh --check  только проверить (код 1, если что-то не так)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

bad=0
fixed=0
while IFS= read -r f; do
  if ! grep -qP '[^\x00-\x7F]' "$f"; then continue; fi      # чистый ASCII — BOM не нужен
  if [ "$(head -c3 "$f" | xxd -p)" = "efbbbf" ]; then continue; fi
  if [ "$CHECK_ONLY" = "1" ]; then
    printf 'НЕТ BOM: %s\n' "${f#"$ROOT"/}"
    bad=$((bad + 1))
  else
    tmp="$(mktemp)"
    printf '\xef\xbb\xbf' >"$tmp"
    cat "$f" >>"$tmp"
    chmod --reference="$f" "$tmp" 2>/dev/null || true
    mv "$tmp" "$f"
    printf 'BOM добавлен: %s\n' "${f#"$ROOT"/}"
    fixed=$((fixed + 1))
  fi
done < <(find "$ROOT/windows" "$ROOT/tests" -name '*.ps1' -type f | sort)

if [ "$CHECK_ONLY" = "1" ]; then
  [ "$bad" = 0 ] && echo 'Все .ps1 с кириллицей имеют UTF-8 BOM.' || echo "Файлов без BOM: $bad"
  exit $([ "$bad" = 0 ] && echo 0 || echo 1)
fi
[ "$fixed" = 0 ] && echo 'BOM уже на месте во всех нужных файлах.' || echo "Исправлено файлов: $fixed"
