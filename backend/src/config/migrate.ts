import fs from 'fs';
import path from 'path';
import { logger } from '../utils/logger.util';
import pool from './database';
import { encryptText, hashForLookup } from '../utils/encryption.util';

// Creates the schema on a fresh database (managed hosts like Railway start
// empty, unlike local Docker which auto-runs init.sql). No-op if already initialized.
export async function runMigrations(): Promise<void> {
    const { rows } = await pool.query("SELECT to_regclass('public.users') AS exists");
    if (rows[0]?.exists) {
        logger.info('Database schema already initialized, skipping migration.');
    } else {
        logger.info('No existing schema found — running init.sql to create tables...');
        const initSqlPath = path.join(__dirname, '../../database/init.sql');
        const initSql = fs.readFileSync(initSqlPath, 'utf-8');
        await pool.query(initSql);
        logger.info('Database schema created successfully.');
    }

    await ensureEmailEncryption();
    await ensureSessionVersionColumn();
    await ensureSessionsTable();
    await ensureGroupChatColumns();
    await ensurePollTables();
}

// Encrypts leftover plaintext emails from before email encryption existed.
// Safe to re-run: only touches rows without an email_hash yet.
async function ensureEmailEncryption(): Promise<void> {
    await pool.query('ALTER TABLE users ADD COLUMN IF NOT EXISTS email_hash VARCHAR(64)');
    await pool.query('CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_hash ON users(email_hash)');

    const { rows } = await pool.query('SELECT id, email FROM users WHERE email_hash IS NULL');
    for (const row of rows) {
        const normalizedEmail = row.email.trim().toLowerCase();
        await pool.query('UPDATE users SET email = $2, email_hash = $3 WHERE id = $1', [
            row.id,
            encryptText(row.email),
            hashForLookup(normalizedEmail),
        ]);
    }
    if (rows.length > 0) {
        logger.info(`Encrypted ${rows.length} plaintext user email(s) at rest.`);
    }
}

// Adds the session_version column for DBs created before single-session
// login existed. No longer read by the application (see ensureSessionsTable
// below), kept only so existing rows aren't left with a missing column.
async function ensureSessionVersionColumn(): Promise<void> {
    await pool.query('ALTER TABLE users ADD COLUMN IF NOT EXISTS session_version INTEGER NOT NULL DEFAULT 0');
}

// Adds the `sessions` table for DBs created before multi-session/selective-logout
// support existed (see SessionRepository). No-op for new installs — init.sql
// already creates it.
async function ensureSessionsTable(): Promise<void> {
    await pool.query(`
        CREATE TABLE IF NOT EXISTS sessions (
            id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            platform VARCHAR(20) NOT NULL DEFAULT 'mobile',
            device_name TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            last_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            revoked_at TIMESTAMP
        )
    `);
    await pool.query(
        'CREATE INDEX IF NOT EXISTS idx_sessions_user_active ON sessions(user_id) WHERE revoked_at IS NULL',
    );
}

// Adds group chat support (chats.is_group/name/created_by, chat_participants.role,
// invites.chat_id) for DBs created before it existed. No-op for new installs —
// init.sql already creates these columns.
async function ensureGroupChatColumns(): Promise<void> {
    await pool.query('ALTER TABLE chats ADD COLUMN IF NOT EXISTS is_group BOOLEAN NOT NULL DEFAULT FALSE');
    await pool.query('ALTER TABLE chats ADD COLUMN IF NOT EXISTS name TEXT');
    await pool.query('ALTER TABLE chats ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users(id) ON DELETE SET NULL');

    await pool.query("ALTER TABLE chat_participants ADD COLUMN IF NOT EXISTS role VARCHAR(20) NOT NULL DEFAULT 'member'");
    // Postgres has no "ADD CONSTRAINT IF NOT EXISTS" — check pg_constraint first so re-running this doesn't error.
    const { rows } = await pool.query(
        "SELECT 1 FROM pg_constraint WHERE conname = 'chat_participants_role_check'",
    );
    if (rows.length === 0) {
        await pool.query(
            "ALTER TABLE chat_participants ADD CONSTRAINT chat_participants_role_check CHECK (role IN ('owner', 'member'))",
        );
    }

    await pool.query('ALTER TABLE invites ADD COLUMN IF NOT EXISTS chat_id UUID REFERENCES chats(id) ON DELETE CASCADE');
    await pool.query('CREATE INDEX IF NOT EXISTS idx_invites_chat_id ON invites(chat_id) WHERE chat_id IS NOT NULL');
}

// Adds polls/poll_options/poll_votes for DBs created before they existed.
// No-op for new installs — init.sql already creates these tables.
async function ensurePollTables(): Promise<void> {
    await pool.query(`
        CREATE TABLE IF NOT EXISTS polls (
            id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
            chat_id UUID REFERENCES chats(id) ON DELETE CASCADE,
            creator_id UUID REFERENCES users(id) ON DELETE SET NULL,
            question TEXT NOT NULL,
            is_anonymous BOOLEAN NOT NULL DEFAULT FALSE,
            allow_multiple_answers BOOLEAN NOT NULL DEFAULT FALSE,
            is_closed BOOLEAN NOT NULL DEFAULT FALSE,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )`);
    await pool.query(`
        CREATE TABLE IF NOT EXISTS poll_options (
            id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
            poll_id UUID REFERENCES polls(id) ON DELETE CASCADE,
            option_text TEXT NOT NULL,
            position INT NOT NULL DEFAULT 0
        )`);
    await pool.query(`
        CREATE TABLE IF NOT EXISTS poll_votes (
            poll_id UUID REFERENCES polls(id) ON DELETE CASCADE,
            option_id UUID REFERENCES poll_options(id) ON DELETE CASCADE,
            user_id UUID REFERENCES users(id) ON DELETE CASCADE,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (poll_id, option_id, user_id)
        )`);
    await pool.query('CREATE INDEX IF NOT EXISTS idx_poll_options_poll ON poll_options(poll_id)');
    await pool.query('CREATE INDEX IF NOT EXISTS idx_poll_votes_poll ON poll_votes(poll_id)');
}
