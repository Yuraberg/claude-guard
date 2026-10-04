# claude-guard — правила работы для агента

Этот репозиторий — защита аккаунта Anthropic: Claude Code и Claude Desktop запускаются
только из-под VPN с выходом вне РФ и только если Anthropic принимает текущий выход.
Политика **fail-closed**. Обе платформенные ветки (`windows/`, `linux/`) содержат одну и ту
же логику проверок.

## Структура

```
windows/            PowerShell-комплект: страж, сторож, установщик, ярлык, задачи Планировщика
linux/              bash-комплект (она же для WSL): bin/{claude-guard,claude-desktop-guard,
                    claude-desktop-watchdog}, install.sh, systemd/
tests/              bash-tests.sh, unit-thresholds.sh, linux-install-e2e.sh (Linux-ветка),
                    unit-thresholds.ps1, win-guard-harness.ps1 (Windows без Windows),
                    win-e2e.ps1 (только на настоящей Windows)
scripts/            build-archive.sh — архив для переноса на другую машину
docs/               how-it-works, threat-model, pitfalls, testing, install, roadmap
decisions/          почему решения именно такие (ADR)
private/            личные документы, в git не попадают (.gitignore)
```

## Железные правила

1. **Никогда не писать в файл `claude` в `PATH` через `>`** (Linux: `~/.local/bin/claude`).
   Он может быть симлинком на бинарь Claude Code (сотни МБ) — запись уходит по ссылке и
   **затирает сам бинарь**. Только `rm -f` + запись, как в `--install`; после установки
   проверять `claude --version`.
2. **Не тестировать гашение по штатным шаблонам на живой машине** — сторож реально закрывает
   запущенный Claude Desktop. Только подсaдная утка с суженным `WATCH_PATTERNS` либо `--dry-run`.
3. **Fail-closed не ослаблять.** Обход `CLAUDE_GUARD_OVERRIDE=1` — только вручную, факт обхода
   пишется в журнал.
4. **Любая правка логики → прогон всех наборов тестов** (см. `docs/testing.md`). Тесты уже
   находили настоящие дефекты: часовой пояс, источники IP, потеря причины отказа, расхождение
   документации с кодом, смещение времени в самих тестах, утечка IPv6. Новую проверку в
   стражу добавлять вместе с симуляцией (`CLAUDE_GUARD_SIM=…`), юнит-тестом на пороги и
   строкой в `docs/how-it-works.md`.
5. **Изменения делать в репозитории**, затем ставить в рабочие пути (`install -m 755 …`) —
   не наоборот: правка «на месте» теряется при переустановке и расходится с репозиторием.
6. **Пороги и сигналы** (`REGION_FRESH`, `REGION_STALE`, `API403_*`) менять только вместе с
   тестами: они отвечают за «свежая жалоба блокирует и помечает выход, 120–900 с — только
   предупреждение, старше — игнор». Новые права/проверки дублировать в обеих ветках
   (`windows/` и `linux/`) и в тестовых наборах обеих платформ, иначе ветки разъедутся.

## Как проверять

```bash
./tests/bash-tests.sh                                 # Linux-ветка, песочница
./tests/unit-thresholds.sh                            # пороги времени Linux (без сети)
./tests/linux-install-e2e.sh                          # установка/снятие в изолированном HOME
pwsh -NoProfile -File tests/unit-thresholds.ps1       # пороги времени Windows (без сети)
pwsh -NoProfile -File tests/win-guard-harness.ps1     # Windows-ветка (на Linux или в CI)
powershell -File tests/win-e2e.ps1                    # только на Windows: задачи, PATH, адаптеры
```

Все прогоны изолированы (`CLAUDE_GUARD_STATE` / `CLAUDE_GUARD_HOME` / `CLAUDE_GUARD_LOGS_DIR`
в песочнице) и не затрагивают рабочую систему; в CI к ним добавлен джоб `windows-native`
(см. `.github/workflows/tests.yml`).

## Прочее

- Коммиты — локальные; ничего не пушить и не публиковать без явного согласия владельца.
- Тексты — по-русски (аудитория русскоязычная), код и идентификаторы — как есть.
- Личные заметки (пути, состояние своих машин, бэкапы) — только в `private/`.
