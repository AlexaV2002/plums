# Plums: Bionic handoff

Snapshot: 2026-10-02. Verify current files before each task.

## Setup

Create a Bionic project named Plums, enable Allow coding, and choose
`C:\Users\alexa\Projects\plums` as its working directory.
Select a Local model in the session model picker. At inspection time,
LM Studio had `qwen/qwen3.8-27b` loaded with a 32768-token context.
This does not prove that the Bionic session has selected that model.
Settings > General > Root model sets the default for new sessions.

Official references:
- https://lmstudio.ai/docs/bionic/agent/code-project
- https://lmstudio.ai/docs/bionic/models

## Current implementation

NestJS/Prisma backend and a Flutter desktop client. Implemented in code:
- Registration, login, rotating refresh tokens, logout, profile editing.
- Servers, invitations, channel CRUD, member listing, kick and ban/unban.
- Text message CRUD, cursor pagination, Socket.IO updates.
- Role model, role CRUD, assignment/removal, merged server permissions.
- Flutter role management dialogs and role/member-role event handlers.

`docs/TZ_COMPLIANCE.md` and `docs/AI_PROJECT_CONTEXT.md` are stale about
roles. Do not recreate the existing roles feature based on those documents.
No implementation found for direct messages, attachment uploads, real voice,
video circles, unread notifications, password recovery or password changes.
Mobile readiness and multi-user realtime behavior are not verified.

Backend verification: 12 suites / 46 tests pass; TypeScript build typecheck passes.
Flutter `analyze --no-pub` completed with exit code 1: 26 findings
(3 warnings, 23 infos, no error-level diagnostics). Findings include async
BuildContext usage, unnecessary null assertions and deprecated APIs.
No application build or two-user runtime test was performed in this audit.
Passing mocked unit tests does not establish PostgreSQL concurrency behavior.
Several existing tests only check dependency injection.
The corrupted unassignRole error message is fixed, but the test still checks
only P2017 and exception type, not P2025 or the exact message.

## Working instructions

Respond in Russian. Read this file and applicable repository instructions.
Start with git status and preserve all existing uncommitted changes.
One small task per session. Read only relevant files; use rg for discovery.
No web search, extra agents, new dependencies, commit or push for the task below.
Do not read .env files or print credentials. Do not change production code,
main.dart, migrations, channel permissions, messages, kick or ban for this task.
Report actual command results; never claim a command ran if it did not.

## First task

Modify only `backend/src/roles/roles.service.spec.ts`.
Read `backend/src/roles/roles.service.ts` for context without editing it.
Replace the existing P2017 disconnect test with a parameterized test for
P2017 and P2025. For each code assert NotFoundException, the exact message
already present in the service's unassignRole catch block, and no call to
emitMemberRolesUpdate. Invoke unassignRole once per case and reuse its promise
for assertions. Preserve all other tests and use existing mocks.

Run from backend:
```powershell
npx.cmd jest src/roles/roles.service.spec.ts --runInBand
npx.cmd tsc --noEmit --incremental false -p tsconfig.build.json
```

Review git diff. Report changed files, checks, and remaining limitations in
at most 8 lines. This test does not prove real concurrent database behavior.

## Next milestones

1. Complete role regression coverage and check realtime with two users.
2. Verify concurrent role mutations against an isolated PostgreSQL test DB.
3. Update the stale role sections in the project documentation.
4. Implement direct messages as separate backend and client tasks.
