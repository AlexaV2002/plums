# Plums

Отвечай на русском языке. Работай кратко и по существу.

## Проект

- `backend` — NestJS + Prisma.
- `client` — Flutter.
- REST-клиент использует Dio.
- Realtime использует Socket.IO.
- Prisma schema: `backend/prisma/schema.prisma`.
- Общий контекст проекта (реализованные фичи, что нельзя ломать): `docs/AI_PROJECT_CONTEXT.md`.
- Сверка с ТЗ: `docs/TZ_COMPLIANCE.md`.

## Правила работы

- Сначала проверь `git status`.
- При неясности, что уже реализовано, сверься с `docs/AI_PROJECT_CONTEXT.md` вместо чтения кода целиком.
- Читай только файлы, связанные с задачей.
- Используй `rg` для поиска.
- Не читай весь проект без необходимости.
- Перед изменением найди controller, service, DTO и client API-метод.
- Для realtime дополнительно найди gateway и client handler.
- Меняй только необходимые файлы.
- Используй минимальный diff.
- В репозитории не настроен `core.autocrlf`/`.gitattributes`, часть файлов на диске в CRLF. Перед коммитом проверяй `git diff --stat` — если изменённый тобой файл показывает диф на весь файл при небольшой правке, построчные окончания могли слететь; нормализуй их в LF перед коммитом, не смешивая с реальными изменениями.
- Не делай несвязанный рефакторинг.
- Не удаляй пользовательские изменения.
- Не меняй generated-файлы без необходимости.
- Не меняй macOS generated-файлы при работе с Windows-клиентом.
- Не добавляй зависимости без прямой необходимости.
- Не делай commit или push без просьбы.

## Backend

- Backend является источником истины для авторизации и прав.
- Проверяй JWT и членство пользователя на backend.
- Проверяй права на каждом защищенном endpoint.
- Не полагайся только на скрытие кнопок в клиенте.
- После Prisma schema создавай новую migration.
- Не редактируй уже примененные migrations.
- После Prisma-изменений запускай `npx.cmd prisma generate`.
- Realtime отправляй только после успешной записи в базу.
- Сохраняй существующие HTTP-коды ошибок.

## Flutter

- Используй существующий `ApiClient`.
- Используй существующий `RealtimeClient`.
- Не дублируй обработку 401.
- Не оставляй бесконечный loading без error-state.
- Не вызывай `setState` после dispose.
- Не добавляй дубликаты realtime-объектов.
- При удалении выбранного объекта выбирай следующий доступный.
- При отсутствии объектов используй существующий empty-state.
- Не меняй UI без прямого запроса.

## Realtime

- Проверяй `serverId` и `channelId` каждого события.
- События должны быть идемпотентными.
- `message:update` обновляет только нужное сообщение.
- `message:delete` удаляет только нужное сообщение.
- `channel:update` не создает дубликаты.
- `channel:delete` очищает выбранный канал.
- `member:leave` корректно обрабатывает последний сервер.
- Статусы обновляются у всех клиентов.
- Проверяй realtime минимум двумя пользователями.

## Проверки

После backend-изменений:

```powershell
cd backend
npx.cmd tsc --noEmit --incremental false -p tsconfig.build.json
```

После Flutter-изменений:

```powershell
cd client
flutter analyze
```

# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.