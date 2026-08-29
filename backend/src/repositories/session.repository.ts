import pool from '../config/database';
import { Session } from '../models/session.model';

// Backs multi-device login and per-device logout: each login creates a row,
// and it stays valid until its own `revoked_at` is set.
export class SessionRepository {
    static async create(userId: string, platform: string, deviceName: string | null): Promise<Session> {
        const result = await pool.query(
            `INSERT INTO sessions (user_id, platform, device_name)
             VALUES ($1, $2, $3) RETURNING *`,
            [userId, platform, deviceName],
        );
        return result.rows[0];
    }

    // Used by the auth middleware and socket handshake on every request/connection.
    static async isActive(sessionId: string, userId: string): Promise<boolean> {
        const result = await pool.query(
            'SELECT 1 FROM sessions WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL',
            [sessionId, userId],
        );
        return (result.rowCount ?? 0) > 0;
    }

    // Lists this user's currently active (non-revoked) sessions/devices, most recently active first.
    static async listActive(userId: string): Promise<Session[]> {
        const result = await pool.query(
            `SELECT * FROM sessions WHERE user_id = $1 AND revoked_at IS NULL
             ORDER BY last_seen_at DESC`,
            [userId],
        );
        return result.rows;
    }

    // Best-effort freshness marker for the "active sessions" UI; failures are
    // non-fatal (see call sites), so a slow/failed write never blocks a connection.
    static async touchLastSeen(sessionId: string): Promise<void> {
        await pool.query('UPDATE sessions SET last_seen_at = CURRENT_TIMESTAMP WHERE id = $1', [sessionId]);
    }

    // Revokes one specific session belonging to userId (selective logout). Returns
    // false if it doesn't exist, belongs to someone else, or was already revoked.
    static async revoke(sessionId: string, userId: string): Promise<boolean> {
        const result = await pool.query(
            `UPDATE sessions SET revoked_at = CURRENT_TIMESTAMP
             WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL`,
            [sessionId, userId],
        );
        return (result.rowCount ?? 0) > 0;
    }
}
