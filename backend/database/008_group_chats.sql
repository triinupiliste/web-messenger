-- Group chats + group invitations.
-- Historical/documentation migration only — matches init.sql. The actual
-- runtime migration for existing databases lives in ensureGroupChatColumns()
-- in backend/src/config/migrate.ts.

ALTER TABLE chats ADD COLUMN IF NOT EXISTS is_group BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS name TEXT;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE chat_participants ADD COLUMN IF NOT EXISTS role VARCHAR(20) NOT NULL DEFAULT 'member';
ALTER TABLE chat_participants ADD CONSTRAINT chat_participants_role_check CHECK (role IN ('owner', 'member'));

ALTER TABLE invites ADD COLUMN IF NOT EXISTS chat_id UUID REFERENCES chats(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_invites_chat_id ON invites(chat_id) WHERE chat_id IS NOT NULL;
