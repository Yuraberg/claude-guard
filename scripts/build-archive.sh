#!/usr/bin/env bash
# Сборка архива комплекта для переноса на другую машину.
# Кладёт в $CLAUDE_GUARD_OUT (по умолчанию ./dist рядом с репозиторием):
#   claude-guard-portable-YYYYMMDD.tar.gz  — архив
#   claude-guard-portable/                 — распакованная копия (удобно копировать на флешку)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${CLAUDE_GUARD_OUT:-$ROOT/dist}"
NAME="claude-guard-portable-$(date +%Y%m%d)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/claude-guard-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

PKG="$STAGE/claude-guard-portable"
mkdir -p "$PKG"
# cp -a: сохраняем атрибуты/время, иначе sha256 архива меняется от сборки к сборке
cp -a "$ROOT/windows" "$PKG/windows"
cp -a "$ROOT/linux" "$PKG/linux"
cp -a "$ROOT/docs/install.md" "$PKG/README.md"

chmod 755 "$PKG/linux/bin/"* "$PKG/linux/install.sh" 2>/dev/null || true
find "$PKG" -name '.DS_Store' -delete
find "$PKG" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/claude-guard-portable"
cp -a "$PKG" "$OUT_DIR/claude-guard-portable"
# --sort/--mtime/--numeric-owner: архив воспроизводим (тот же sha256 при том же коде),
# иначе время сборки попадает в заголовки и хэш «плавает»
tar --owner=0 --group=0 --numeric-owner --sort=name --mtime='2026-01-01 00:00:00' \
    -czf "$OUT_DIR/$NAME.tar.gz" -C "$STAGE" claude-guard-portable

# контроль: архивы и распакованная копия совпадают с проектом
for f in linux/bin/claude-guard windows/claude-guard.ps1 windows/claude-watchdog.ps1; do
  cmp -s "$OUT_DIR/claude-guard-portable/$f" "$ROOT/$f" || { echo "РАСХОЖДЕНИЕ: $f" >&2; exit 1; }
done

echo "файлы:  $(find "$PKG" -type f | wc -l)"
echo "архив:  $OUT_DIR/$NAME.tar.gz"
echo "копия:  $OUT_DIR/claude-guard-portable/"
sha256sum "$OUT_DIR/$NAME.tar.gz"
