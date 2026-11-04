# План автоматических проверок Windows MVP

Матрица описывает проверки в ветке C01. После исправления гонки и согласования контракта ЛС прошли 164 backend unit-теста, 46 backend e2e и 102 Flutter-теста. Unit и widget-тесты с подменами не заменяют e2e с PostgreSQL и Socket.IO или ручную проверку двух клиентов.

| Сценарий | Обязательная автоматическая проверка | Уровень |
| --- | --- | --- |
| Регистрация, вход, refresh, повторное использование, истечение и logout | `backend/test/auth-refresh.e2e-spec.ts` | PostgreSQL e2e |
| Два конкурентных refresh | `backend/test/auth-refresh.e2e-spec.ts` | PostgreSQL e2e |
| Роли, выдача/отзыв разрешений, отказ постороннему, удаление и ban | `backend/test/realtime-access.e2e-spec.ts`, `backend/test/channel-visibility.e2e-spec.ts` | PostgreSQL и Socket.IO e2e |
| Лимит, повторное вступление, срок действия и параллельные приглашения | `backend/test/invite-concurrency.e2e-spec.ts` | PostgreSQL e2e |
| Канальные сообщения, идемпотентность, конкурентная отправка и права | `backend/test/message-idempotency.e2e-spec.ts` | PostgreSQL e2e |
| Курсоры и восстановление 50, 51, 60 и 120 сообщений; удалённый курсор | `backend/test/message-reconnect-sync.e2e-spec.ts`; дополнительные граничные случаи — `backend/src/messages/messages.service.spec.ts` | PostgreSQL e2e и unit |
| Истечение JWT, выход из комнат и повторная идентификация | `backend/test/realtime-access.e2e-spec.ts` | PostgreSQL и реальный Socket.IO e2e, короткий TTL |
| Устаревший сокет при смене пользователя/истечении во время join | `backend/src/messages/messages.gateway.spec.ts` | unit с подменами |
| Удаление канала во время выполняющегося join | `backend/test/realtime-access.e2e-spec.ts` | PostgreSQL и Socket.IO e2e; исправление проверено в одном процессе backend |
| ЛС: история, права, удаление, события | `backend/test/dm-contract.e2e-spec.ts`; `client/test/dm_test.dart` | PostgreSQL e2e и Flutter с подменами |
| Изображения: тип, размер, доступ, конкурентная привязка, очистка, перезапуск | `backend/test/attachments.e2e-spec.ts`; `backend/test/profile-images.e2e-spec.ts` | PostgreSQL e2e, временное файловое хранилище |
| Загрузка, ошибки, retry, выбор диалога и отсутствие дублей | `client/test/channel_states_test.dart`, `client/test/dm_test.dart`, `client/test/attachments_test.dart` | Flutter widget с подменами |
| Переподключение, позиция и клавиатура | `client/test/realtime_session_test.dart`, `client/test/reconnect_sync_anchor_test.dart`, `client/test/message_history_position_test.dart`, `client/test/message_input_test.dart` | Flutter-тесты; не заменяют проверку Windows-клиентов |

## Подготовка отдельной тестовой среды в PowerShell

Команды ниже создают **два новых временных контейнера без томов** на портах 55460 и 55461. Убедитесь, что имена контейнеров и порты свободны. Они не используют существующий `plums_postgres`, его тома или рабочую БД на порту 5432. Если команда создания контейнера завершилась ошибкой, остановитесь и выясните причину; не подставляйте существующую БД. Контейнеры и все их данные будут удалены при их остановке благодаря `--rm`.

```powershell
cd C:\Users\alexa\Projects\plums\.worktrees\c01-mvp-tests\backend
npm ci
docker run -d --rm --name plums_c01_e2e -e POSTGRES_USER=c01_test -e POSTGRES_PASSWORD=c01_test -e POSTGRES_DB=plums_c01_test -p 127.0.0.1:55460:5432 postgres:16
docker run -d --rm --name plums_c01_auth -e POSTGRES_USER=c01_test -e POSTGRES_PASSWORD=c01_test -e POSTGRES_DB=plums_auth_test_c01 -p 127.0.0.1:55461:5432 postgres:16
docker exec plums_c01_e2e pg_isready -U c01_test -d plums_c01_test
docker exec plums_c01_auth pg_isready -U c01_test -d plums_auth_test_c01
```

Если `pg_isready` сообщает, что сервер ещё не готов, повторите соответствующую команду. Затем в **том же окне PowerShell** задайте тестовые адреса и примените миграции только к этим двум временным базам:

```powershell
$env:DATABASE_URL = 'postgresql://c01_test:c01_test@127.0.0.1:55460/plums_c01_test?schema=public'
$env:TEST_DATABASE_URL = $env:DATABASE_URL
$env:AUTH_TEST_DATABASE_URL = 'postgresql://c01_test:c01_test@127.0.0.1:55461/plums_auth_test_c01?schema=public'
$env:JWT_SECRET = 'c01-local-test-secret-only'
npx.cmd prisma generate
npx.cmd prisma migrate deploy
$env:DATABASE_URL = $env:AUTH_TEST_DATABASE_URL
npx.cmd prisma migrate deploy
$env:DATABASE_URL = $env:TEST_DATABASE_URL
```

Перед каждым `migrate deploy` проверьте напечатанную Prisma базу и порт: сначала `plums_c01_test` / 55460, затем `plums_auth_test_c01` / 55461. Не используйте `migrate reset`. Оба URL должны указывать на разные временные базы: общий guard проверяет совпадение `DATABASE_URL` и `TEST_DATABASE_URL` и наличие `test` в имени; auth-тест отдельно проверяет локальный адрес, порт и имя. Это защита от ошибок, но само имя не доказывает, что база не содержит пользовательские данные.

## Запуск и ожидаемый результат

```powershell
# В backend, в том же PowerShell с тестовыми переменными:
npm.cmd test -- --runInBand
npm.cmd run test:e2e -- --runInBand

# В отдельном терминале:
cd C:\Users\alexa\Projects\plums\.worktrees\c01-mvp-tests\client
flutter pub get
flutter test
flutter analyze
```

Для Jest и Flutter ожидаются завершение без упавших тестов и код 0. `flutter analyze` может вернуть код 1 из-за информационных замечаний; проверьте, что нет новых `error` или `warning`, и запишите полный итог. Для нового worktree нужны свои зависимости; `npm ci` и `flutter pub get` могут потребовать интернет.

Гонка удаления канала и `join` подтверждена первым прогоном и исправлена; повторный e2e прошёл. Синхронизация действует внутри одного процесса backend: при нескольких экземплярах необходимы распределённая координация и отдельные тесты. Гонки kick/ban и каскадного удаления сервера с незавершённым `join` этим исправлением отдельно не закрыты.

После прогона остановите **только** созданные C01 контейнеры:

```powershell
docker stop plums_c01_e2e plums_c01_auth
Remove-Item Env:DATABASE_URL,Env:TEST_DATABASE_URL,Env:AUTH_TEST_DATABASE_URL,Env:JWT_SECRET -ErrorAction SilentlyContinue
```

E2E создают уникальные тестовые аккаунты и удаляют созданные ими записи по ID. Файлы тестов направляются в `backend/.tmp`; не указывайте путь к рабочему хранилищу. При аварийном завершении проверьте оставшиеся временные файлы отдельно, не удаляя пользовательские изображения.

## Ручная регрессия

На двух Windows-клиентах проверьте регистрацию/вход, права и отзыв доступа, 60+ сообщений с переподключением и пагинацией, ЛС, изображения и удаление. Проверьте сообщение об ошибке и восстановление после отключения сети. Фактические ошибки оформляйте отдельными задачами, не исправляя продуктовый код в C01.
