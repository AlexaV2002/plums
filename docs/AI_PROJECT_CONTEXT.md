# Plums — AI Project Context

This document is the working context for AI assistants and Codex when helping with the Plums project. Its purpose is to reduce accidental regressions and keep development aligned with the product requirements.

## Project overview

Plums is a Discord-like cross-platform messenger.

Primary MVP target: Windows desktop.

Tech stack:

- Backend: NestJS, TypeScript, Prisma, PostgreSQL, Socket.IO.
- Client: Flutter/Dart, Dio, socket_io_client, shared_preferences.
- Repository structure:
  - `backend/` — Nest