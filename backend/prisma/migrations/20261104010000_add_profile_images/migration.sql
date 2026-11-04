-- Existing avatarUrl and iconUrl values are deliberately left unchanged.
ALTER TABLE "users" ADD COLUMN "profileImageRevision" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "servers" ADD COLUMN "profileImageRevision" INTEGER NOT NULL DEFAULT 0;
CREATE TABLE "profile_images" (
  "id" TEXT PRIMARY KEY,
  "userId" TEXT UNIQUE REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE,
  "serverId" TEXT UNIQUE REFERENCES "servers"("id") ON DELETE CASCADE ON UPDATE CASCADE,
  "mimeType" TEXT NOT NULL CHECK ("mimeType" IN ('image/jpeg', 'image/png', 'image/webp')),
  "sizeBytes" INTEGER NOT NULL CHECK ("sizeBytes" > 0 AND "sizeBytes" <= 10485760),
  "storageKey" TEXT NOT NULL UNIQUE,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "profile_images_exactly_one_owner" CHECK (("userId" IS NULL) <> ("serverId" IS NULL))
);
CREATE TRIGGER "profile_images_enqueue_cleanup" BEFORE DELETE ON "profile_images"
  FOR EACH ROW EXECUTE FUNCTION "enqueue_attachment_cleanup"();
