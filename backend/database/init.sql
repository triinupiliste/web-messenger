-- Enable UUID extension for secure unique identifiers
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. Users Table (Handles Registration, Auth, & Unique Constraints)
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email TEXT NOT NULL, -- Stored as encrypted text payload (AES-256-CBC); see email_hash for lookups
    email_hash VARCHAR(64) NOT NULL, -- Deterministic HMAC-SHA256 of the normalized email, used for exact-match login/registration lookups since `email` itself is ciphertext. Unique index created by ensureEmailEncryption() in migrate.ts (shared code path with legacy databases).
    username VARCHAR(100) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    is_verified BOOLEAN DEFAULT FALSE,
    verification_token VARCHAR(255),
    verification_token_expires TIMESTAMP,
    reset_token VARCHAR(255),
    reset_token_expires TIMESTAMP,
    fcm_token TEXT, -- Firebase Cloud Messaging token for push notifications
    session_version INTEGER NOT NULL DEFAULT 0, -- Bumped on every login; a JWT whose embedded version no longer matches is rejected, enforcing a single active login session per account
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for fast search and unique lookups
CREATE INDEX idx_users_username ON users(username);
CREATE INDEX idx_users_verification_token ON users(verification_token)
    WHERE verification_token IS NOT NULL;

-- 2. Profiles Table (Handles Profile Picture, About Me, and Encryption)
CREATE TABLE profiles (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    avatar_url TEXT, -- Can store path or encrypted URL
    about_me TEXT -- Stored as encrypted text payload
);

-- 3. Invites Table (Handles Chat Invitations — both 1:1 friend invites and
-- invitations to join an existing group chat)
CREATE TABLE invites (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sender_id UUID REFERENCES users(id) ON DELETE CASCADE,
    receiver_id UUID REFERENCES users(id) ON DELETE CASCADE,
    status VARCHAR(20) DEFAULT 'pending', -- 'pending', 'accepted', 'declined'
    chat_id UUID REFERENCES chats(id) ON DELETE CASCADE, -- NULL for a 1:1 friend invite; set for a group invite (join this chat on accept)
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 4. Chats Table (Base entity for conversations — 1:1 or group)
CREATE TABLE chats (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    is_group BOOLEAN NOT NULL DEFAULT FALSE,
    name TEXT, -- Group display name, stored as encrypted text payload. NULL for 1:1 chats.
    created_by UUID REFERENCES users(id) ON DELETE SET NULL, -- Group creator/owner; NULL for 1:1 chats
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 5. Chat Participants (Manages 1-on-1 or group memberships, archiving, and muting per user)
CREATE TABLE chat_participants (
    chat_id UUID REFERENCES chats(id) ON DELETE CASCADE,
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    role VARCHAR(20) NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'member')), -- Group-only: 'owner' can rename/remove members; meaningless (always 'member') for 1:1 chats
    is_archived BOOLEAN DEFAULT FALSE,
    is_muted BOOLEAN DEFAULT FALSE, -- Satisfies the chat muting requirement
    is_deleted BOOLEAN DEFAULT FALSE, -- Per-user "delete chat" (hides it from that user's list only)
    cleared_at TIMESTAMP, -- Hides messages sent before this time, for this user only
    PRIMARY KEY (chat_id, user_id)
);

-- 6. Messages Table (Handles Text, Media/Audio, Statuses, Editing, Deleting, and Encryption)
CREATE TABLE messages (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    chat_id UUID REFERENCES chats(id) ON DELETE CASCADE,
    sender_id UUID REFERENCES users(id) ON DELETE CASCADE,
    content TEXT, -- Stored as encrypted text payload
    media_url TEXT, -- Path for images, videos, or audio files (size-limited at app level)
    media_type VARCHAR(50), -- 'image', 'video', 'audio', 'text'
    status VARCHAR(20) DEFAULT 'sent', -- 'sent', 'delivered', 'read'
    is_edited BOOLEAN DEFAULT FALSE,
    is_deleted BOOLEAN DEFAULT FALSE,
    reply_to_id UUID REFERENCES messages(id) ON DELETE SET NULL, -- Message being replied to, if any
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Index to sort and query chat list messages quickly
CREATE INDEX idx_messages_chat_created ON messages(chat_id, created_at DESC);

-- 7. Sessions Table (Enables multiple concurrent logins per account — one row
-- per device/browser — and selective, per-device logout. Replaces the older
-- single-session `users.session_version` counter, which is no longer read;
-- that column is left in place, unused, for backward compatibility with existing rows.)
CREATE TABLE sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    platform VARCHAR(20) NOT NULL DEFAULT 'mobile', -- 'mobile' or 'web'
    device_name TEXT, -- Human-readable label shown in the "Active sessions" UI
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    revoked_at TIMESTAMP -- NULL while the session is active; set on logout / selective logout
);

-- Speeds up "list my active sessions" and the auth check performed on every request/socket connection.
CREATE INDEX idx_sessions_user_active ON sessions(user_id) WHERE revoked_at IS NULL;

-- Speeds up "pending invites for this group" duplicate-invite checks.
CREATE INDEX idx_invites_chat_id ON invites(chat_id) WHERE chat_id IS NOT NULL;