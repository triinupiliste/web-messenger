import pool from '../config/database';
import { User, Profile } from '../models/user.model';
import { encryptText, decryptFields, hashForLookup } from '../utils/encryption.util';

// Email is stored encrypted (see email_hash below); decrypt before handing
// rows back to callers that expect plaintext.
function withDecryptedEmail<T extends { email?: string | null }>(row: T): T {
    return decryptFields(row, ['email']) as T;
}

export class UserRepository {
    // Matched via the deterministic email_hash, since the encrypted email column
    // can't be matched with SQL `=`. Callers must pass an already-normalized email.
    static async findByEmailOrUsername(email: string, username: string): Promise<User | null> {
        const query = 'SELECT * FROM users WHERE email_hash = $1 OR username = $2';
        const result = await pool.query(query, [hashForLookup(email), username]);
        return result.rows[0] ? withDecryptedEmail(result.rows[0]) : null;
    }

    // Same as above but excludes the given user, so a profile update doesn't
    // flag the user's own unchanged email/username as taken.
    static async findByEmailOrUsernameExcludingUser(
        email: string,
        username: string,
        excludeUserId: string,
    ): Promise<User | null> {
        const query = 'SELECT * FROM users WHERE (email_hash = $1 OR username = $2) AND id != $3';
        const result = await pool.query(query, [hashForLookup(email), username, excludeUserId]);
        return result.rows[0] ? withDecryptedEmail(result.rows[0]) : null;
    }

    static async createUser(
        email: string,
        username: string,
        passwordHash: string,
        verificationToken: string,
        verificationTokenExpires: Date,
    ): Promise<User> {
        const client = await pool.connect();
        try {
            await client.query('BEGIN');
            const userQuery = `
                INSERT INTO users (
                    email, email_hash, username, password_hash,
                    verification_token, verification_token_expires
                )
                VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`;
            const userResult = await client.query(userQuery, [
                encryptText(email),
                hashForLookup(email),
                username,
                passwordHash,
                verificationToken,
                verificationTokenExpires,
            ]);
            const user: User = withDecryptedEmail(userResult.rows[0]);

            await client.query('INSERT INTO profiles (user_id) VALUES ($1)', [user.id]);
            await client.query('COMMIT');
            return user;
        } catch (error) {
            await client.query('ROLLBACK');
            throw error;
        } finally {
            client.release();
        }
    }

    static async getProfile(userId: string): Promise<Profile | null> {
        const query = `
            SELECT u.id, u.id AS user_id, u.email, u.username,
                   p.avatar_url, p.about_me
            FROM users u
            LEFT JOIN profiles p ON u.id = p.user_id
            WHERE u.id = $1`;
        const result = await pool.query(query, [userId]);
        if (!result.rows[0]) return null;

        return decryptFields(result.rows[0], ['email', 'avatar_url', 'about_me']) as Profile;
    }

    static async updateProfile(
        userId: string,
        updates: { username?: string; email?: string; avatarUrl?: string; aboutMe?: string },
    ): Promise<Profile> {
        const { username, email, avatarUrl, aboutMe } = updates;
        // Encrypt avatarUrl/aboutMe before writing to DB as per data encryption requirements
        const encryptedAvatarUrl = avatarUrl ? encryptText(avatarUrl) : null;
        const encryptedAboutMe = aboutMe ? encryptText(aboutMe) : null;
        const encryptedEmail = email ? encryptText(email) : null;
        const emailHash = email ? hashForLookup(email) : null;

        const client = await pool.connect();
        try {
            await client.query('BEGIN');

            await client.query(
                `UPDATE users
                 SET username = COALESCE($2, username),
                     email = COALESCE($3, email),
                     email_hash = COALESCE($4, email_hash)
                 WHERE id = $1`,
                [userId, username ?? null, encryptedEmail, emailHash],
            );

            await client.query(
                `UPDATE profiles
                 SET avatar_url = COALESCE($2, avatar_url),
                     about_me = COALESCE($3, about_me)
                 WHERE user_id = $1`,
                [userId, encryptedAvatarUrl, encryptedAboutMe],
            );

            const result = await client.query(
                `SELECT u.id, u.id AS user_id, u.email, u.username, p.avatar_url, p.about_me
                 FROM users u
                 LEFT JOIN profiles p ON u.id = p.user_id
                 WHERE u.id = $1`,
                [userId],
            );

            await client.query('COMMIT');

            return decryptFields(result.rows[0], ['email', 'avatar_url', 'about_me']) as Profile;
        } catch (error) {
            await client.query('ROLLBACK');
            throw error;
        } finally {
            client.release();
        }
    }

    static async searchUsers(searchTerm: string, currentUserId: string): Promise<User[]> {
        // relationship_status lets the client show "Friends"/"Pending" instead of an
        // Invite button. Declined/removed invites are excluded so that pair can be invited again.
        const query = `
            SELECT u.id, u.email, u.username, u.created_at, p.avatar_url,
                (SELECT cp1.chat_id FROM chat_participants cp1
                    JOIN chat_participants cp2 ON cp1.chat_id = cp2.chat_id
                    WHERE cp1.user_id = $2 AND cp2.user_id = u.id
                    LIMIT 1) AS chat_id,
                CASE
                    WHEN EXISTS (
                        SELECT 1 FROM invites i
                        WHERE i.status = 'accepted'
                          AND ((i.sender_id = $2 AND i.receiver_id = u.id)
                            OR (i.sender_id = u.id AND i.receiver_id = $2))
                    ) THEN 'friends'
                    WHEN EXISTS (
                        SELECT 1 FROM invites i
                        WHERE i.status = 'pending'
                          AND ((i.sender_id = $2 AND i.receiver_id = u.id)
                            OR (i.sender_id = u.id AND i.receiver_id = $2))
                    ) THEN 'pending'
                    ELSE 'none'
                END AS relationship_status
            FROM users u
            LEFT JOIN profiles p ON u.id = p.user_id
            WHERE (u.username ILIKE $1 OR u.email_hash = $3) AND u.id != $2 AND u.is_verified = TRUE
            ORDER BY u.username
            LIMIT 10`;
        // Username matches via ILIKE (public, searchable). Email is encrypted at
        // rest, so it only matches via its deterministic hash — the full address is required.
        // Unverified accounts are excluded so users can't be found/invited before
        // confirming their email.
        const result = await pool.query(query, [
            `%${searchTerm}%`,
            currentUserId,
            hashForLookup(searchTerm.trim().toLowerCase()),
        ]);
        return result.rows.map((row: any) => decryptFields(row, ['email', 'avatar_url']));
    }

    static async existsById(userId: string): Promise<boolean> {
        const result = await pool.query('SELECT 1 FROM users WHERE id = $1', [userId]);
        return result.rowCount === 1;
    }

    static async updateFcmToken(userId: string, fcmToken: string): Promise<void> {
        await pool.query('UPDATE users SET fcm_token = $2 WHERE id = $1', [userId, fcmToken]);
    }

    // Lightweight lookup for push notification payloads, without pulling/decrypting a full profile.
    static async getPushInfoById(userId: string): Promise<{ username: string; fcm_token: string | null } | null> {
        const result = await pool.query(
            'SELECT username, fcm_token FROM users WHERE id = $1',
            [userId],
        );
        return result.rows[0] || null;
    }

    static async verifyEmail(verificationToken: string): Promise<User | null> {
        const query = `
            UPDATE users
            SET is_verified = TRUE,
                verification_token = NULL,
                verification_token_expires = NULL
            WHERE verification_token = $1
              AND verification_token_expires > CURRENT_TIMESTAMP
              AND is_verified = FALSE
            RETURNING *`;
        const result = await pool.query(query, [verificationToken]);
        return result.rows[0] || null;
    }

    static async setVerificationToken(
        userId: string,
        verificationToken: string,
        verificationTokenExpires: Date,
    ): Promise<void> {
        await pool.query(
            `UPDATE users
             SET verification_token = $2, verification_token_expires = $3
             WHERE id = $1 AND is_verified = FALSE`,
            [userId, verificationToken, verificationTokenExpires],
        );
    }

    static async setResetToken(
        userId: string,
        resetTokenHash: string,
        resetTokenExpires: Date,
    ): Promise<void> {
        await pool.query(
            `UPDATE users
             SET reset_token = $2, reset_token_expires = $3
             WHERE id = $1`,
            [userId, resetTokenHash, resetTokenExpires],
        );
    }

    // Atomically consumes the reset token: only succeeds if it's still valid
    // and unexpired, and clears it afterwards so it can't be replayed.
    static async resetPassword(resetTokenHash: string, passwordHash: string): Promise<User | null> {
        const query = `
            UPDATE users
            SET password_hash = $2,
                reset_token = NULL,
                reset_token_expires = NULL
            WHERE reset_token = $1
              AND reset_token_expires > CURRENT_TIMESTAMP
            RETURNING *`;
        const result = await pool.query(query, [resetTokenHash, passwordHash]);
        return result.rows[0] || null;
    }
}