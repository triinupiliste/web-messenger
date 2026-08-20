-- NOTE: init.sql now creates the `sessions` table directly, so this
-- migration is only needed for a database created before it existed. Safe
-- to re-run (uses IF NOT EXISTS); not required for a fresh clone. Also
-- auto-applied on every server startup via ensureSessionsTable() in
-- migrate.ts, so running this file by hand is not required either — it's
-- kept here purely for schema history.
--
-- Backs multi-device login and selective, per-device logout: one row per
-- logged-in device/browser, valid until its own `revoked_at` is set. This
-- replaces the older `users.session_version` counter (see
-- 006_single_session_login.sql), which only allowed a single active session
-- account-wide and is no longer read by the application — that column is
-- left in place, unused, for backward compatibility with existing rows.
CREATE TABLE IF NOT EXISTS sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    platform VARCHAR(20) NOT NULL DEFAULT 'mobile', -- 'mobile' or 'web'
    device_name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    revoked_at TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_sessions_user_active ON sessions(user_id) WHERE revoked_at IS NULL;
