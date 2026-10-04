# claude-guard

![tests](https://github.com/Yuraberg/claude-guard/actions/workflows/tests.yml/badge.svg)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Запускает **Claude Code** и **Claude Desktop** только тогда, когда трафик гарантированно
уходит вне РФ **и** Anthropic принимает текущий выход. Иначе — отказ запуска, а уже
работающий Claude закрывается сторожем. Политика **fail-closed**: любая неясность
трактуется как запрет.

Зачем: Anthropic не обслуживает РФ, и запросы с российского IP — риск блокировки аккаунта.
Отдельный случай: выход VPN формально не РФ (например, датацентровый), но сервис считает
регион неподдерживаемым (`region_unavailable`) — такие выходы тоже надо распознавать и не
долбиться в них.

```
┌──────── проверка перед каждым запуском (fail-closed) ─────────┐
│ 1. VPN-интерфейс поднят (tun/tap/wg/WireGuard/Wintun/TAP …)   │
│ 2. интернет идёт через него                                    │
│ 3. нет глобального маршрута IPv6 мимо туннеля (утечка IP)      │
│ 4. страна выхода ≠ РФ — двумя путями (как ходит CLI и напрямую) │
│ 5. Anthropic принимает этот выход (вердикт из логов Desktop)   │
└───────────────────────────────────────────────────────────────┘
              │ всё ок                     │ любая неясность
              ▼                            ▼
        Claude стартует            запуск отменяется + уведомление
```

## Что внутри

| Часть | Роль |
|---|---|
| **Страж** (`claude-guard`) | пять проверок перед стартом; подменяет запуск `claude` (обёртка в `PATH` / шим в Windows) |
| **Сторож** (`claude-watchdog`) | во время работы: нет туннеля 2 замера подряд (~30 с) или свежая жалоба Anthropic → Claude закрывается |
| **Защита Desktop** | запуск только через ярлык с проверкой (GUI нельзя перехватить подменой), дальше — сторож |
| **Самолечение** | обновление Claude Code через npm возвращает свой `claude`; таймер/задача Планировщика возвращает защиту |

Две ветки, одна логика проверок:

| Платформа | Папка |
|---|---|
| Windows 10/11 | [`windows/`](windows/) — PowerShell: шим `claude.cmd` + `.ps1` в `PATH`, ярлык «Claude (с VPN)», две задачи Планировщика |
| Linux и WSL | [`linux/`](linux/) — bash: обёртка `~/.local/bin/claude`, сторож в `systemd --user`, самолечение таймером |

Установка не требует админа/root и снимается одной командой.

## Установка

```powershell
# Windows: распаковать архив и в папке windows
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
claude-guard.ps1 -Doctor
claude-guard.ps1 -SelfTest
```

```bash
# Linux / WSL: в папке linux
./install.sh            # в WSL без systemd: ./install.sh --no-systemd
claude-guard --doctor
claude-guard --self-test
```

Подробная инструкция (что должно получиться, что смотреть при отказе, что проверить после
установки) — [`docs/install.md`](docs/install.md).

### Убедиться, что защита действительно срабатывает

```bash
CLAUDE_GUARD_SIM=ru-exit   claude -p "тест"   # ожидается отказ, код 1
CLAUDE_GUARD_SIM=no-tun    claude -p "тест"   # ожидается отказ, код 1
CLAUDE_GUARD_SIM=region    claude -p "тест"   # ожидается отказ с советом «смени узел»
CLAUDE_GUARD_SIM=ipv6-leak claude -p "тест"   # утечка IPv6 → ожидается отказ, код 1
claude-guard --self-test                     # 6 симуляций → «защита работает как задумано»
```

```powershell
$env:CLAUDE_GUARD_SIM='ru-exit'; claude -p "тест"; $env:CLAUDE_GUARD_SIM=''
$env:CLAUDE_GUARD_FORCE_DOWN='1'; .\claude-watchdog.ps1 -Once -DryRun; $env:CLAUDE_GUARD_FORCE_DOWN=''
```

## Как это работает

Пять проверок, пороги свежести, файлы состояния, сторож и самолечение —
[`docs/how-it-works.md`](docs/how-it-works.md).
От чего защищает и от чего **не** защищает — [`docs/threat-model.md`](docs/threat-model.md).
Почему решения именно такие — [`decisions/`](decisions/).

Коротко про проверку вердикта Anthropic: публичного «примет ли Anthropic этот IP» нет —
`api.anthropic.com` отдаёт 401 с любого выхода, `claude.ai` закрыт Cloudflare-челленджем.
Поэтому берётся вердикт самого Claude Desktop из его логов: строка `region_unavailable` →
выход запоминается как плохой, и пока он текущий, запуск отменяется. Смена узла в VPN-клиенте
снимает пометку сама (другой IP).

## Команды стража

```bash
claude-guard --status           # туннель, страна выхода, вердикт Anthropic, плохие выходы
claude-guard --check            # 0 = можно, 1 = нельзя (для скриптов и cron)
claude-guard --check-cli        # только туннель + страна (то, что важно CLI и API)
claude-guard --self-test        # 6 симуляций, ничего не ломает
claude-guard --doctor           # что найдено в системе
claude-guard --install          # поставить/починить обёртку (идемпотентно)
claude-guard --uninstall        # снять защиту
claude-guard --mark-blocked [IP]   # пометить выход как отклонённый Anthropic
claude-guard --reset-web-block     # очистить память о плохих выходах
```

## Ограничения

- Расширение Claude Code для VS Code стражем не покрыто — защита только маршрутизацией VPN.
- Claude Desktop из Microsoft Store нельзя перехватить подменой запуска: защита от запуска —
  ярлык «Claude (с VPN)», после запуска — сторож.
- При обрыве VPN сторож закрывает Claude: несохранённые черновики могут потеряться. Это
  осознанный выбор в пользу «не выйти из РФ молча».
- Проверка вердикта Anthropic опирается на логи Claude Desktop: если Desktop не запускался, жалоб нет и шаг
  молча пропускает (проверки туннеля и страны работают всегда).

## Дисклеймер

Инструмент управляет тем, какой IP видит сервис, и предназначен для защиты аккаунта при
работе через VPN. Используйте его в рамках правил и условий Anthropic и законодательства
своей страны; автор не несёт ответственности за последствия применения. Это не средство
обхода оплаты или получения доступа к сервису, который вам недоступен.

## Разработка

```bash
./tests/bash-tests.sh                                # Linux-ветка: 29 проверок (в песочнице)
./tests/unit-thresholds.sh                           # пороги времени: свежесть/устаревание, память IP
./tests/linux-install-e2e.sh                         # установка и снятие в изолированном HOME (--no-systemd)
pwsh -NoProfile -File tests/unit-thresholds.ps1      # то же для Windows-ветки
pwsh -NoProfile -File tests/win-guard-harness.ps1    # Windows-ветка без Windows
powershell -File tests/win-e2e.ps1                   # установка/Планировщик/пути — только на Windows
./scripts/ps1-ensure-bom.sh --check                   # .ps1 с кириллицей: есть ли UTF-8 BOM
./scripts/build-archive.sh                           # архив для переноса (./dist + sha256)
```

Оба прогона работают в песочнице и не трогают рабочую систему. Что именно проверяется —
[`docs/testing.md`](docs/testing.md); грабли, на которых уже ошибались — [`docs/pitfalls.md`](docs/pitfalls.md).
Всё то же самое гоняется в CI ([`.github/workflows/tests.yml`](.github/workflows/tests.yml)).

## Лицензия

[MIT](LICENSE).
