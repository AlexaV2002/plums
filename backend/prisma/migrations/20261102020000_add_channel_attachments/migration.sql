-- File contents remain in private storage; only metadata is stored here.
CREATE TYPE "AttachmentState" AS ENUM ('UPLOADED', 'ATTACHED');

CREATE TABLE "attachments" (
    "id" TEXT NOT NULL,
    "ownerId" TEXT NOT NULL,
    "channelId" TEXT NOT NULL,
    "messageId" TEXT,
    "originalName" TEXT NOT NULL,
    "mimeType" TEXT NOT NULL,
    "sizeBytes" INTEGER NOT NULL,
    "storageKey" TEXT NOT NULL,
    "state" "AttachmentState" NOT NULL DEFAULT 'UPLOADED',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "expiresAt" TIMESTAMP(3),
    CONSTRAINT "attachments_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "attachments_state_message_check" CHECK (
        ("state" = 'UPLOADED' AND "messageId" IS NULL AND "expiresAt" IS NOT NULL)
        OR ("state" = 'ATTACHED' AND "messageId" IS NOT NULL)
    ),
    CONSTRAINT "attachments_size_check" CHECK ("sizeBytes" > 0 AND "sizeBytes" <= 10485760),
    CONSTRAINT "attachments_mime_check" CHECK ("mimeType" IN ('image/jpeg', 'image/png', 'image/webp'))
);

CREATE UNIQUE INDEX "attachments_storageKey_key" ON "attachments"("storageKey");
CREATE INDEX "attachments_ownerId_state_createdAt_idx" ON "attachments"("ownerId", "state", "createdAt");
CREATE INDEX "attachments_state_expiresAt_idx" ON "attachments"("state", "expiresAt");
CREATE INDEX "attachments_channelId_idx" ON "attachments"("channelId");
CREATE INDEX "attachments_messageId_idx" ON "attachments"("messageId");

ALTER TABLE "attachments" ADD CONSTRAINT "attachments_ownerId_fkey"
    FOREIGN KEY ("ownerId") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "attachments" ADD CONSTRAINT "attachments_channelId_fkey"
    FOREIGN KEY ("channelId") REFERENCES "channels"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "attachments" ADD CONSTRAINT "attachments_messageId_fkey"
    FOREIGN KEY ("messageId") REFERENCES "messages"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- The queue has no foreign keys: cascading deletes must not erase blob keys.
CREATE TABLE "attachment_cleanup" (
    "storageKey" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "attempts" INTEGER NOT NULL DEFAULT 0,
    "lastAttemptAt" TIMESTAMP(3),
    CONSTRAINT "attachment_cleanup_pkey" PRIMARY KEY ("storageKey")
);

-- Runs for explicit deletes and cascades, in the same database transaction.
CREATE FUNCTION "enqueue_attachment_cleanup"() RETURNS trigger AS $$
BEGIN
    INSERT INTO "attachment_cleanup" ("storageKey") VALUES (OLD."storageKey")
    ON CONFLICT ("storageKey") DO NOTHING;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER "attachments_enqueue_cleanup"
    BEFORE DELETE ON "attachments"
    FOR EACH ROW EXECUTE FUNCTION "enqueue_attachment_cleanup"();
