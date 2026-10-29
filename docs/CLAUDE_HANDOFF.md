# Передача работы по Plums

Актуально на 29.10.2026. Рабочая папка: `C:\Users\alexa\Projects\plums`, ветка `feature/roles-and-permissions`.

## Состояние

- Проект: NestJS + Prisma + PostgreSQL в `backend`, Flutter в `client`.
- Claude Code в этом проекте запускается как `plums-coordinator` через `.claude/settings.json`; исполнители `backend-implementer`, `frontend-implementer`, `database-implementer` определены в `.claude/agents/`.
- В репозитории много незакоммиченных изменений, часть существовала до последней задачи. Сначала выполни `git status --short`; не сбрасывай и не перезаписывай их. Коммит и push не запрашивались.
- Правила проекта: `CLAUDE.md`. Контекст и план выпуска: `docs/AI_PROJECT_CONTEXT.md`, `docs/TZ_COMPLIANCE.md`.

## Последняя задача: доступ к Socket.IO и переподключение

- `server:join` проверяет установленный `client.data.userId` и членство. Дублирующий обработчик в `ChannelsGateway` удалён.
- `channel:join` проверяет членство и `canView`; владелец сервера может видеть скрытый канал.
- После выхода, kick, ban, удаления сервера и отзыва `canView` сокеты исключаются из соответствующих комнат.
- `presence:identify` отдаёт ack через `@Ack()`; при смене аккаунта очищает защищённые комнаты.
- Flutter `RealtimeClient` при переподключении получает актуальный access token через `ApiClient.getMe()`, ждёт ack и восстанавливает сервер и выбранный канал.
- Для запуска backend исправлен импорт `JwtModule` в `backend/src/dm/dm.module.ts`; `PrismaService` теперь закрывает пул при остановке.

## Проверено

- `npx.cmd prisma migrate status`: 11 миграций, схема актуальна; Docker PostgreSQL работает.
- `npx.cmd tsc --noEmit --incremental false -p tsconfig.build.json`: успешно.
- `npm.cmd test -- --runInBand --silent`: 94 теста проходят.
- `npm.cmd run test:e2e -- --runInBand realtime-access.e2e-spec.ts`: сквозной тест с двумя пользователями проходит. Файл: `backend/test/realtime-access.e2e-spec.ts`.
- ESLint для изменённых backend файлов проходит.
- `flutter analyze lib/main.dart`: 26 ранее существовавших замечаний, новых ошибок компиляции нет.
- `flutter test`: прежний `client/test/widget_test.dart` падает из-за ожидания текста «Вход в plums».

## Следующий шаг

Проверь реальное восстановление выбранного канала именно Flutter-клиентом после обрыва соединения: backend e2e проверяет повторное Socket.IO-подключение, но не запускает Flutter UI. Затем выбери следующую задачу выпуска по `docs/TZ_COMPLIANCE.md`. Сохраняй текущие пользовательские изменения и сообщай о найденных проблемах до правки широких участков кода.
