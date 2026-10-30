-- Existing messages keep NULL and remain unchanged. PostgreSQL permits
-- multiple NULLs in this unique index for legacy clients.
ALTER TABLE "messages" ADD COLUMN "clientMessageId" TEXT;

CREATE UNIQUE INDEX "messages_authorId_channelId_clientMessageId_key"
ON "messages"("authorId", "channelId", "clientMessageId");
