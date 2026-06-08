# Plums — AI Project Context

This document is the stable project context for AI assistants and Codex when helping with the Plums project.

Its purpose is to reduce accidental regressions, keep development aligned with the product requirements, and prevent AI from fixing one place while breaking another.

This file should contain stable project information only. Temporary bugs, active tasks, and unfinished issues should be tracked in GitHub Projects and GitHub Issues, not hardcoded here as permanent context.

---

## 1. Project overview

Plums is a Discord-like cross-platform messenger.

The main product idea:

```text
A modern messenger with servers, channels, roles, text messages, voice channels, direct messages, files, and video circle messages.
```

Primary MVP target:

```text
Windows desktop
```

Development strategy:

```text
1. Build working MVP logic first.
2. Keep backend and client behavior stable.
3. Commit small features.
4. Track tasks through GitHub Projects.
5. Refactor the client structure later.
6. Redesign UI according to the UX/UI specification after core logic is stable.
```

The current UI is a working prototype. It is not final design.

---

## 2. Repository and local paths

GitHub repository:

```text
AlexaV2002/plums
```

Local project path:

```text
C:\Users\alexa\Projects\plums
```

Product requirements documents:

```text
C:\Users\alexa\Desktop\Plums.docx
C:\Users\alexa\Downloads\Plums_UX_UI_TZ.docx
```

Repository structure:

```text
plums/
  backend/
  client/
  docs/
```

---

## 3. Tech stack

Backend:

```text
NestJS
TypeScript
Prisma
PostgreSQL
Socket.IO
JWT auth
```

Client:

```text
Flutter / Dart
Windows desktop target first
Dio
socket_io_client
shared_preferences
```

Database:

```text
PostgreSQL
Prisma ORM
```

Realtime:

```text
Socket.IO
```

Version control and planning:

```text
Git
GitHub
GitHub Projects
GitHub Issues
```

---

## 4. Current architecture principle

The project is currently in MVP-building mode.

Important:

```text
client/lib/main.dart is currently large.
This is known technical debt.
Do not split it during unrelated feature work unless the task is specifically about refactoring.
```

Current client architecture is acceptable temporarily because the priority is to validate product logic.

Future desired client structure:

```text
client/lib/
  core/
    api/
    realtime/
    storage/
    theme/
  features/
    auth/
    profile/
    servers/
    invites/
    members/
    channels/
    messages/
    voice/
  shared/
    widgets/
    dialogs/
    models/
```

Do not start this refactor casually. It should be a separate planned task.

---

## 5. Implemented product areas

### 5.1 Auth

Implemented:

```text
Registration
Login
JWT Bearer auth
Desktop login screen
Desktop registration screen
Token persistence with shared_preferences
Session restore after app restart
Logout button
```

Expected behavior:

```text
After login, accessToken is saved locally.
After app restart, the app restores the token and calls GET /users/me.
If token is valid, the app opens the main screen.
If token is invalid, the token is cleared and login screen opens.
Logout clears the saved token and returns to login screen.
```

Relevant backend endpoints:

```text
POST /auth/register
POST /auth/login
GET /users/me
```

Do not break:

```text
accessToken response from login
Authorization: Bearer <token>
GET /users/me session restore
logout token clearing
```

---

### 5.2 User profile

Implemented:

```text
Get current user profile
Edit username
Edit bio
Edit status
Display user in bottom user panel
```

Existing user fields:

```text
id
email
username
avatarUrl
status
bio
createdAt
updatedAt
```

Relevant backend endpoints:

```text
GET /users/me
PATCH /users/me
```

Not implemented yet:

```text
User avatar upload
Change password
Password reset
```

Do not break:

```text
username
email
bio
status
avatarUrl field
```

---

### 5.3 Servers

Implemented:

```text
Create server
Get user's servers
Get server by id
Rename server
Delete own server
Leave joined server
Server owner automatically becomes a server member
```

Relevant backend endpoints:

```text
POST /servers
GET /servers
GET /servers/:id
PATCH /servers/:id
DELETE /servers/:id
DELETE /servers/:id/members/me
```

Expected behavior:

```text
User sees only servers where they are a member.
Owner can rename server.
Owner can delete server.
Non-owner can leave server.
Owner cannot leave their own server.
Server owner is stored as ownerId.
```

Desktop UI implemented:

```text
Server sidebar
Create server
Select server
Rename server
Delete own server
Leave joined server
```

Do not break:

```text
ownerId in server responses
GET /servers filtering by membership
server member creation when server is created
```

---

### 5.4 Invites

Implemented:

```text
Create invite
Get invite by code
Join server by invite
Desktop UI for invite creation
Desktop UI for joining server by invite code/link
```

Relevant backend endpoints:

```text
POST /servers/:serverId/invites
GET /invites/:code
POST /invites/:code/join
```

Expected behavior:

```text
Owner can create invite.
User can join server using invite code or invite link.
After joining, server appears in user's server list.
```

Do not break:

```text
invite code
join invite flow
server membership creation after invite join
```

---

### 5.5 Server members

Implemented:

```text
Get server members
Display server members in desktop UI
Kick server member
```

Relevant backend endpoints:

```text
GET /servers/:id/members
DELETE /servers/:id/members/:memberId
```

Expected behavior:

```text
Any server member can view the server member list.
Only server owner can kick members.
Owner cannot kick themselves.
Owner cannot be kicked.
Member cannot be kicked from a different server through wrong serverId.
After kick, membership is removed from server_members.
```

Desktop UI implemented:

```text
Members button in chat header
Members dialog
Kick button for owner
```

Do not break:

```text
server_members relation
GET /servers filtering by membership
owner protection
```

---

### 5.6 Channels

Implemented:

```text
Create text channel
Create voice channel as entity
Get server channels
Rename channel
Delete channel
Edit channel permissions
```

Relevant backend endpoints:

```text
POST /servers/:serverId/channels
GET /servers/:serverId/channels
PATCH /channels/:channelId
DELETE /channels/:channelId
PATCH /channels/:channelId/permissions
```

Channel types:

```text
TEXT
VOICE
```

Channel permissions:

```text
canView
canSendMessages
canConnect
```

Expected behavior:

```text
Owner can manage channels.
Owner bypasses channel permissions.
Normal members do not see channels where canView=false.
Normal members cannot send messages where canSendMessages=false.
canConnect is stored for future voice behavior.
```

Desktop UI implemented:

```text
Text channel list
Voice channel list
Create channel
Rename channel
Delete channel
Channel permissions dialog
Voice channel placeholder
```

Do not break:

```text
TEXT / VOICE enum values
permissions JSON shape
owner bypass
normal member restrictions
serverId in channel responses
```

---

### 5.7 Text messages

Implemented:

```text
Send message
Get message history
Edit own message
Delete own message
Soft delete through deletedAt
Show edited indicator
```

Relevant backend endpoints:

```text
POST /channels/:channelId/messages
GET /channels/:channelId/messages
PATCH /messages/:messageId
DELETE /messages/:messageId
```

Expected behavior:

```text
Messages can only be sent to TEXT channels.
Users can edit only their own messages.
Users can delete only their own messages.
Deleted messages are hidden from history.
Edited messages display “изменено” in the client.
```

Desktop UI implemented:

```text
Message history
Message input
Send message
Edit message
Delete message
Edited indicator
```

Do not break:

```text
createdAt
updatedAt
deletedAt
channelId
authorId
author object in message responses
```

---

### 5.8 Realtime

Implemented realtime events:

```text
server:join
server:leave
channel:join
channel:leave
message:new
message:update
message:delete
channel:new
channel:update
channel:delete
```

Expected behavior:

```text
Clients join server rooms for server-level updates.
Clients join channel rooms for message-level updates.
New messages appear without manual refresh.
Edited messages update without manual refresh.
Deleted messages disappear without manual refresh.
New/renamed/deleted channels update without manual refresh.
```

Do not break:

```text
Socket.IO connection
server rooms
channel rooms
message:new
message:update
message:delete
channel:new
channel:update
channel:delete
```

Future realtime events may include:

```text
server:member:kicked
server:member:joined
role:update
presence:update
typing:start
typing:stop
```

---

## 6. Product areas not finished yet

The following areas are planned by product requirements but are not fully implemented.

### 6.1 Roles and permissions

Needed:

```text
Server roles
Role name
Role color
Role permission set
Assign roles to members
Remove roles from members
Check permissions through roles
Admin / moderator / member role behavior
```

Current state:

```text
Only simple channel permissions exist.
Full Discord-like role system is not implemented yet.
```

---

### 6.2 Direct messages

Needed:

```text
Search user
Create direct conversation
Send direct message
Get direct message history
Realtime direct messages
Delete own direct messages
```

Current state:

```text
Not implemented.
```

---

### 6.3 Files, images, avatars, server icons

Needed:

```text
Upload user avatar
Upload server icon
Upload image attachment
Upload file attachment
Display attachments in messages
Store files locally or in S3-compatible storage
```

Current state:

```text
avatarUrl and iconUrl fields exist.
Actual upload flow is not implemented yet.
```

---

### 6.4 Notifications and unread indicators

Needed:

```text
Unread channel indicators
Unread server indicators
New message notifications
Mute server
Mute channel
Notification settings
```

Current state:

```text
Not implemented.
```

---

### 6.5 Voice channel MVP

Needed:

```text
Join voice channel
Leave voice channel
Mute
Deafen
Display voice channel participants
Realtime voice participant updates
```

Current state:

```text
Voice channels exist as entities.
Client shows voice channel placeholder.
No real voice behavior yet.
```

---

### 6.6 Real voice via WebRTC

Needed later:

```text
Real audio communication
WebRTC signaling
Peer connection handling
Audio device controls
```

Current state:

```text
Not implemented.
```

---

### 6.7 Video circle messages

Needed:

```text
Send video circle message
Store video file
Display video circle in chat
Play video circle in UI
Realtime event for new video message
```

Current state:

```text
Not implemented.
```

Recommended dependency:

```text
Implement general file/video attachments first.
Then implement video circles on top of that.
```

---

### 6.8 UI redesign

Needed later:

```text
Redesign according to UX/UI specification
Improve visual hierarchy
Improve desktop layout
Prepare mobile layout
Split UI into proper feature files
```

Current state:

```text
Current UI is a working MVP prototype.
Do not treat it as final design.
```

---

## 7. GitHub Project workflow

GitHub Project columns:

```text
Backlog
Next
In Progress
Testing
Done
```

Column meaning:

```text
Backlog — planned but not soon
Next — near-term task
In Progress — being worked on now
Testing — implemented but needs manual verification
Done — tested, committed, pushed
```

Labels:

```text
feature
bug
ui
backend
frontend
realtime
refactor
tech-debt
docs
mvp
p0
p1
p2
p3
```

Priority meaning:

```text
p0 — app cannot run or core flow is broken
p1 — required for MVP
p2 — useful for MVP but not immediate blocker
p3 — later
```

Task format:

```text
Задача: <issue title>
По ТЗ: да / частично / нет, tech-debt
Ярлыки: <labels>
Куда занести: <Backlog / Next / In Progress / Testing / Done>
Коммит: <commit message>
```

---

## 8. Current board baseline

Done or should be Done if already committed and tested:

```text
Auth: registration, login and JWT
User profile editing
Server creation and server list
Server management actions
Invite links and join server flow
Channel CRUD
Channel permissions
Text message CRUD
Realtime messages and channels
Show edited indicator for messages
Server members list
Save auth token after app restart
Add logout button
Add server member actions: kick user
```

Backlog examples:

```text
Roles and permissions
Direct messages
File attachments for messages
User avatars
Server icons
Unread message indicators
Notifications
Voice channel MVP
Real voice via WebRTC
Video circle messages
UI redesign according to UX/UI spec
Mobile layout
Password reset
Change password
Emoji picker
Reply to message
Search messages
```

This file is not the task board. If board state changes, GitHub Projects is the source of truth.

---

## 9. What AI must not break

Do not break:

```text
Auth flow
Token persistence
Logout
Session restore
Server list loading
Invite join flow
Server ownership checks
Server member checks
Channel CRUD
Channel permissions
Text message CRUD
Realtime message updates
Realtime channel updates
Owner permission bypass
Normal member permission restrictions
```

Do not remove or casually rename existing API endpoints.

Do not change backend response shapes unless the frontend is updated at the same time.

Do not change enum values casually:

```text
TEXT
VOICE
ONLINE
OFFLINE
AWAY
DO_NOT_DISTURB
```

Do not remove these fields from responses unless the client is updated:

```text
ownerId
serverId
channelId
authorId
createdAt
updatedAt
deletedAt
permissions
```

Do not remove `updatedAt` from messages because the client uses it for the edited indicator.

Do not remove `ownerId` from server responses because the client uses it for owner-only UI actions.

Do not remove `serverId` from channel/message-related responses because realtime handlers rely on it.

---

## 10. AI / Codex working rules

Before editing code:

```text
1. Read the relevant files first.
2. Identify the smallest safe set of files to change.
3. Explain the plan.
4. Make targeted changes.
5. Avoid rewriting unrelated code.
6. Preserve existing behavior unless the task explicitly changes it.
```

For backend changes, run:

```text
npx.cmd tsc --noEmit --incremental false -p tsconfig.build.json
```

For Flutter changes, run:

```text
flutter analyze
flutter run -d windows
```

If Flutter is unavailable in the current environment, say so clearly.

Before commit, run:

```text
git diff --check
git status
```

Commit style:

```text
One feature = one small commit
Use clear commit messages
```

Good commit examples:

```text
Persist auth token and add logout
Add server member kick action
Add realtime server member kick event
Show edited message indicator
Add server members list
```

Avoid vague commits:

```text
fix
changes
update
stuff
```

---

## 11. Recommended product order

Follow product requirements, not random nice-to-have ideas.

Recommended order:

```text
1. Finish unstable MVP behavior and realtime sync gaps.
2. Roles and permissions.
3. Direct messages.
4. File/image attachments.
5. User avatars and server icons.
6. Unread messages and notifications.
7. Voice channel MVP.
8. Video circle messages.
9. UI refactor and redesign according to UX/UI spec.
10. Mobile adaptation.
```

Tech debt note:

```text
Splitting main.dart is important, but it is not a product feature.
Track it as refactor / tech-debt.
Do it when client changes become too risky in one large file.
```

---

## 12. How to use this document

When starting work, AI should check:

```text
1. This document for stable context.
2. GitHub Project for current task state.
3. GitHub Issues for task details.
4. Latest commits.
5. Current conversation context.
6. git status.
```

This document should not contain temporary bug details as permanent truth.

Temporary tasks and bugs belong in:

```text
GitHub Issues
GitHub Projects
Current conversation context
```

If something in this document conflicts with current code, current code and recent commits should be inspected before making changes.

If something in this document conflicts with product requirements, product requirements win.
