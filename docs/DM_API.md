# DM API (личные сообщения)

Все REST-эндпоинты требуют `Authorization: Bearer <accessToken>`. Права проверяет backend.
Реализация: `backend/src/dm/` (мапперы `toDmUser`/`toDmMessage`/`toDmConversation` в `dm.service.ts`).

## Формы

```ts
DmUser         = { id, username, avatarUrl: string | null }   // без email и приватных полей
DmMessage      = { id, conversationId, senderId, content, createdAt, updatedAt, sender: DmUser }
DmConversation = { id, createdAt, updatedAt, userA: DmUser, userB: DmUser, lastMessage: DmMessage | null }
```

- `DmMessage` одинаков в истории, ответе POST, `dm:new` и `lastMessage`. `deletedAt` наружу не отдаётся, удалённые сообщения не возвращаются.
- `userA`/`userB` в каноническом порядке: `userA.id < userB.id` (не зависит от инициатора).
- `updatedAt` диалога = время последнего сообщения (обновляется в одной транзакции с созданием сообщения).

## REST

| Метод | Путь | Тело / query | Ответ |
|---|---|---|---|
| GET | `/dm/conversations` | — | `DmConversation[]`, по `updatedAt desc` (последняя активность сверху) |
| POST | `/dm/conversations` | `{ userId: uuid }` | `201 DmConversation`; идемпотентно: A→B и B→A возвращают один диалог |
| GET | `/dm/conversations/:id/messages` | `?limit=1..100` (по умолч. 50), `?before=<messageId>` или `?after=<messageId>` | `DmMessage[]` от старых к новым; `before`/`after` — составной курсор (createdAt, id); `after` — строго после курсора (догрузка после переподключения); курсор может быть удалённым сообщением, удалённые в ответ не попадают |
| POST | `/dm/conversations/:id/messages` | `{ content: 1..2000 }` | `201 DmMessage`, затем `dm:new` в комнату |
| DELETE | `/dm/messages/:messageId` | — | `204`, затем `dm:delete` в комнату (soft-delete) |

## Коды ошибок

| Код | Когда | Текст |
|---|---|---|
| 400 | диалог с самим собой | `Нельзя создать диалог с самим собой` |
| 400 | `before`/`after` из другого диалога / не существует | `Некорректный курсор пагинации` |
| 400 | `before` и `after` одновременно | `Нельзя одновременно использовать курсоры before и after` |
| 400 | невалидное тело/query (ValidationPipe) | — |
| 401 | нет/просрочен JWT | — |
| 403 | не участник диалога (история, отправка) | `Вы не участник этого диалога` |
| 403 | удаление чужого сообщения | `Можно удалять только свои сообщения` |
| 404 | нет собеседника (`POST /dm/conversations`) | `Пользователь не найден` |
| 404 | нет диалога | `Диалог не найден` |
| 404 | нет сообщения или оно уже удалено | `Сообщение не найдено` |

## Realtime (Socket.IO)

Комната: `dm:<conversationId>`. События уходят только после успешной записи в БД.

- `dm:join` `{ conversationId }` → ack:
  - `{ joined: true, conversationId }`
  - `{ joined: false, conversationId, reason }`, `reason`:
    `unidentified` (нет `presence:identify`, JWT истёк или identity сменилась во время join),
    `not_found` (нет диалога или не передан `conversationId` — тогда `conversationId: null`),
    `forbidden` (не участник).
  - Для обратной совместимости при отказе также эмитится `dm:error { conversationId, error }`
    (кроме смены identity и пустого payload).
- `dm:leave` `{ conversationId }` — без ack.
- `dm:new` → `DmMessage`.
- `dm:delete` → `{ id, conversationId }`.
- `dm:conversation:changed` → `{ conversationId }` только подтверждённым
  сокетам второго участника после создания диалога или отправки сообщения.
  Это сигнал перечитать `GET /dm/conversations`: содержимое сообщения и
  данные собеседника в событие не включаются. Он работает и когда получатель
  ещё не вступил в комнату `dm:<conversationId>`.

При смене identity/выходе сокет автоматически покидает все `dm:*` комнаты.

## Порядок подключения (и переподключения)

1. `connect` → `presence:identify { token }` → дождаться ack `{ userId }`.
2. `dm:join { conversationId }` → дождаться ack `joined: true`.
3. Догрузить историю `GET /dm/conversations/:id/messages` и слить с полученными `dm:new`
   по `id` (события идемпотентны: повторный `dm:new`/`dm:delete` с тем же `id` не дублирует и не ломает состояние).
4. При `joined: false, reason: 'unidentified'` — повторить шаг 1, затем 2.
