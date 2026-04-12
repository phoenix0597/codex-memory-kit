# Codex Memory Kit

Переносимый bootstrap-kit для воспроизведения структуры памяти Codex на любой машине с сохранением ожидаемых runtime-paths.

Если между `README.md` и `README.ru.md` появится расхождение, каноническим считается английский `README.md`.

## Назначение

Kit устанавливает и проверяет трехслойную memory-архитектуру Codex:

1. Глобальная память в `~/.codex/memories/`
2. Home-level bootstrap в `~/AGENTS.md`
3. Project-local memory в `<repo>/AGENTS.md`, `<repo>/START-HERE.md`, `<repo>/assistant-memory.md` и `<repo>/memory/`

Цель kit-а — сделать memory setup воспроизводимым между машинами без жесткой привязки шаблонов к одному username или одному home directory.

## Runtime Layout

После установки ожидаются такие runtime-paths:

- `~/.codex/memories/global-collaboration-rules.md`
- `~/.codex/memories/memory-architecture.md`
- `~/AGENTS.md`
- `<repo>/AGENTS.md`
- `<repo>/START-HERE.md`
- `<repo>/assistant-memory.md`
- `<repo>/memory/current-work-queue.md`
- `<repo>/memory/_templates/daily.md`
- `<repo>/memory/_templates/topic.md`

## Source Layout

- `templates/home/` — шаблоны home-level bootstrap
- `templates/global/` — шаблоны глобальной памяти
- `templates/project/` — шаблоны project-local memory
- `scripts/install.sh` — устанавливает global layer и home bootstrap
- `scripts/init-project.sh` — инициализирует project-local memory в repo
- `scripts/check.sh` — проверяет корректность runtime structure
- `scripts/export-memory.sh` — экспортирует установленную memory-структуру с машины
- `scripts/import-memory.sh` — импортирует ранее экспортированную memory-структуру на машину

## Базовые принципы

- Runtime paths должны оставаться стабильными.
- Source templates должны быть machine-agnostic.
- Absolute paths должны появляться только при рендере на конкретной машине.
- Установка должна быть идемпотентной.
- Проверка должна явно падать на broken startup chains и missing required files.

## Поддерживаемые платформы

Текущий целевой scope:

- Linux
- macOS
- Windows через WSL

Нативные Windows shell environments пока вне scope. Kit опирается на POSIX-style shell scripts и Unix-like path semantics.

## Переменные шаблонов

Шаблоны могут использовать такие placeholders:

- `{{HOME_DIR}}`
- `{{CODEX_DIR}}`
- `{{GLOBAL_MEMORY_DIR}}`
- `{{REPO_ROOT}}`
- `{{PROJECT_NAME}}`

## Разрешение путей по умолчанию

Если не переопределять значения через аргументы scripts:

- `CODEX_DIR` по умолчанию = `{{HOME_DIR}}/.codex`
- `GLOBAL_MEMORY_DIR` по умолчанию = `{{CODEX_DIR}}/memories`

В обычном случае итоговый global memory path такой:

- `~/.codex/memories`

## Bootstrap На Новой Машине

Сначала нужно клонировать repository. Scripts лежат внутри этого repo, поэтому до clone запускать нечего.

Рекомендуемый путь для clone:

```bash
git clone git@github.com:phoenix0597/codex-memory-kit.git ~/.codex/codex-memory-kit
cd ~/.codex/codex-memory-kit
```

Этот путь рекомендуется потому, что source/tooling repo оказывается рядом с live Codex runtime directory, но не смешивается с `~/.codex/memories/`.

## Куда Клонировать

Клонировать repo именно в `~/.codex/codex-memory-kit` не обязательно.

Scripts рендерят runtime files из значений, переданных через `--home`, `--repo` и связанные аргументы, а не из clone location как такового. Поэтому работает и такой вариант:

```bash
git clone git@github.com:phoenix0597/codex-memory-kit.git /some/other/path/codex-memory-kit
cd /some/other/path/codex-memory-kit
```

Достаточно, чтобы выполнялось одно из двух:

- scripts запускаются из самого cloned repo; или
- передан `--source-root /absolute/path/to/codex-memory-kit`

Тогда runtime paths все равно будут отрендерены корректно.

Коротко:

- clone location = где живет source/tooling repo
- `--home` и `--repo` = где создаются runtime files

## Установка

Установить global layer и home bootstrap:

```bash
./scripts/install.sh --home "$HOME"
```

Инициализировать project-local memory в repo:

```bash
./scripts/init-project.sh --repo /path/to/repo --project-name my-project
```

Проверить получившуюся структуру:

```bash
./scripts/check.sh --home "$HOME" --repo /path/to/repo
```

## Режимы

`install.sh` поддерживает:

- обычную установку
- dry-run
- принудительный overwrite через явный `--force`

`check.sh` поддерживает:

- только global checks
- только project checks
- комбинированные checks

## Правила безопасности

- Не перезаписывать существующие файлы без `--force`.
- Не создавать project-local files вне target repo.
- Не пропускать required files молча.
- Не переписывать user-authored memory files во время verification.

## Ожидаемый Workflow

1. Склонировать этот repository в локальный source path.
2. Один раз на машину установить global memory и home bootstrap.
3. Один раз на repository инициализировать project-local memory.
4. Запускать checks после установки или после изменения templates.
5. Держать накопленные daily/topic notes в обычной project version control, а не внутри самого kit-а.

## Что Kit Не Делает

- Это не backup-system сама по себе.
- Это не live-sync memory files между машинами.
- Это не замена project git history.

## Implementation Notes

### Рендер Шаблонов

- Templates должны оставаться machine-agnostic в source form.
- Runtime files могут содержать absolute paths, но только после рендера на target machine.
- Placeholder replacement должен быть явным и ограниченным документированными переменными:
  - `{{HOME_DIR}}`
  - `{{CODEX_DIR}}`
  - `{{GLOBAL_MEMORY_DIR}}`
  - `{{REPO_ROOT}}`
  - `{{PROJECT_NAME}}`
- Рендер должен падать, если template содержит unknown placeholder или если обязательная переменная не задана.
- Не нужно превращать это в generic templating engine; предпочтительна простая детерминированная подстановка placeholders.

### Правила Путей

- Runtime path contract — часть архитектуры и должен оставаться стабильным.
- `install.sh` отвечает только за home/global runtime paths.
- `init-project.sh` отвечает только за repo-local runtime paths.
- `check.sh` должен валидировать runtime structure, а не source template tree.
- Clone location repo kit-а не зависит от runtime target paths.
- Ни один script не должен предполагать фиксированный username вроде `phoenix`; все absolute paths должны выводиться из переданных `--home` или `--repo`.

### Идемпотентность

- Повторный запуск `install.sh` с теми же аргументами должен воспроизводить ту же runtime layout без дублирования содержимого.
- Повторный запуск `check.sh` никогда не должен менять файлы.
- Повторный запуск `init-project.sh` без `--force` должен явно пропускать уже существующие target files.
- Scripts должны быть безопасны для многократного запуска во время setup, migration или repair.

### Политика Перезаписи

- Существующие файлы нельзя перезаписывать по умолчанию.
- Перезапись должна требовать явного `--force`.
- `--force` должен применяться только к файлам, которыми управляет kit, а не к любым extra files рядом.
- Если target file уже существует, script должен явно сообщать один из статусов:
  - `UNCHANGED`
  - `SKIP`
  - `OVERWRITE`
- `check.sh` не должен ничего переписывать даже в strict mode.

### Границы Владения Файлами

- Kit владеет только bootstrap/scaffold files, полученными из его templates.
- Daily notes, topic files, article notes и прочий project-specific working content после создания остаются user/project-owned.
- Verification может проверять их наличие, если того требует архитектура, но не должна нормализовать или переписывать их содержимое.
- Kit не должен удалять файлы, которые не создавал.

### Правила Валидации

- `check.sh` должен валидировать и наличие файлов, и архитектурную согласованность.
- В обычном режиме validation должна фокусироваться на required files и читаемых startup references.
- В `--strict` mode validation должна также ловить:
  - broken startup-order references
  - missing linked files, явно названные в bootstrap files
  - unresolved placeholders, оставшиеся в runtime files
  - явные path mismatches между rendered files и текущим machine layout
- Validation output должна указывать failing file и точное правило, которое не прошло.

### Логи И Вывод

- Scripts должны печатать короткие детерминированные status lines.
- Предпочтительный формат:
  - `CREATE <path>`
  - `SKIP <path>`
  - `OVERWRITE <path>`
  - `CHECK OK <path>`
  - `CHECK FAIL <path>: <reason>`
- `--verbose` может печатать дополнительный контекст, но default output должен оставаться коротким и удобным для сканирования.
- `--dry-run` должен печатать planned actions тем же словарем статусов, но явно помечать их как simulation.

### Поведение При Ошибках

- Scripts должны быстро падать на invalid arguments.
- Scripts должны падать до частичных writes, если отсутствует required source template.
- Если multi-file install оборвался на середине, output должен явно показывать, какие файлы уже были записаны.
- `check.sh` должен возвращать non-zero code на любой failed required check.

### Ограничения Переносимости

- Предпочтительно использовать POSIX shell behavior там, где это практично.
- Не стоит зависеть от Python, GNU-only tools или внешних templating engines, если только это явно не заявлено как prerequisite.
- Если требуется non-POSIX behavior, это должно быть явно задокументировано в prerequisites.
- Home-relative semantics должны сохраняться даже если absolute home path между машинами отличается.

### Политика Апгрейдов

- Изменения templates должны быть forward-applicable через повторный запуск installer с `--force`.
- Kit не должен молча мигрировать user-authored project memory content.
- Если template contract меняется несовместимо, README должен явно описывать migration path.
- `check.sh --strict` должен помогать обнаруживать stale runtime files после upgrade kit-а.
