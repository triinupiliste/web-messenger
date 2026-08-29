// Central place for tunable limits/durations that were previously scattered
// across individual files as inline magic numbers.

export const BCRYPT_SALT_ROUNDS = 10;
export const VERIFICATION_TOKEN_LIFETIME_MS = 24 * 60 * 60 * 1000;
export const RESET_TOKEN_LIFETIME_MS = 15 * 60 * 1000;

// Raw upload accepted before server-side compression brings video under
// MAX_MEDIA_SIZE_BYTES.
export const UPLOAD_SIZE_LIMIT_BYTES = 150 * 1024 * 1024;
// Final size cap enforced after compression, matching the client's limit.
export const MAX_MEDIA_SIZE_BYTES = 20 * 1024 * 1024;
export const AVATAR_SIZE_LIMIT_BYTES = 5 * 1024 * 1024;

// Bounds how much CPU/wall-clock time a single upload's compression can tie
// up on the server, in case ffmpeg gets stuck on a malformed/unusual file.
export const COMPRESSION_TIMEOUT_MS = 5 * 60 * 1000;

export const POLL_MAX_OPTIONS = 10;
export const POLL_MIN_OPTIONS = 2;
export const POLL_MAX_QUESTION_LENGTH = 300;
export const POLL_MAX_OPTION_LENGTH = 100;

// Caps a single chat-search response so a very common term in a huge chat
// doesn't return an unbounded payload.
export const MAX_SEARCH_RESULTS = 200;

// Single source of truth for the message lifecycle values also defined as
// the MessageStatus type (models/message.model.ts), so the literal strings
// aren't duplicated across repositories/controllers.
export const MESSAGE_STATUS = {
    SENT: 'sent',
    DELIVERED: 'delivered',
    READ: 'read',
} as const;
