import pool from '../config/database';
import { ChatListItem, GroupMember } from '../models/chat.model';
import { decryptFields, decryptText, encryptText } from '../utils/encryption.util';

export class ChatRepository {
    static async createChatBetweenUsers(user1Id: string, user2Id: string): Promise<string> {
        const client = await pool.connect();
        try {
            await client.query('BEGIN');
            const chatResult = await client.query('INSERT INTO chats DEFAULT VALUES RETURNING id');
            const chatId = chatResult.rows[0].id;

            await client.query(
                'INSERT INTO chat_participants (chat_id, user_id) VALUES ($1, $2), ($1, $3)',
                [chatId, user1Id, user2Id]
            );

            await client.query('COMMIT');
            return chatId;
        } catch (error) {
            await client.query('ROLLBACK');
            throw error;
        } finally {
            client.release();
        }
    }

    // Looks for a chat that already exists between these users (e.g. from
    // before they unfriended) so re-accepting an invite revives it instead of creating a new one.
    static async findChatBetweenUsers(user1Id: string, user2Id: string): Promise<string | null> {
        const query = `
            SELECT cp1.chat_id FROM chat_participants cp1
            JOIN chat_participants cp2 ON cp1.chat_id = cp2.chat_id
            WHERE cp1.user_id = $1 AND cp2.user_id = $2
            LIMIT 1`;
        const result = await pool.query(query, [user1Id, user2Id]);
        return result.rows[0]?.chat_id || null;
    }

    static async isUserInChat(chatId: string, userId: string): Promise<boolean> {
        const result = await pool.query(
            'SELECT 1 FROM chat_participants WHERE chat_id = $1 AND user_id = $2',
            [chatId, userId],
        );
        return (result.rowCount ?? 0) > 0;
    }

    // --- Group chats ---

    // Creates a new group chat with just the creator as its sole (owner) member;
    // additional members are added afterwards via the invite system (see InviteController).
    static async createGroupChat(creatorId: string, name: string): Promise<string> {
        const client = await pool.connect();
        try {
            await client.query('BEGIN');
            const chatResult = await client.query(
                'INSERT INTO chats (is_group, name, created_by) VALUES (TRUE, $1, $2) RETURNING id',
                [encryptText(name), creatorId],
            );
            const chatId = chatResult.rows[0].id;

            await client.query(
                "INSERT INTO chat_participants (chat_id, user_id, role) VALUES ($1, $2, 'owner')",
                [chatId, creatorId],
            );

            await client.query('COMMIT');
            return chatId;
        } catch (error) {
            await client.query('ROLLBACK');
            throw error;
        } finally {
            client.release();
        }
    }

    // Basic chat metadata, decrypted — used to validate group operations
    // (is this chat actually a group? who's the owner?) before acting on them.
    static async getChatMeta(
        chatId: string,
    ): Promise<{ id: string; is_group: boolean; name: string | null; created_by: string | null } | null> {
        const result = await pool.query(
            'SELECT id, is_group, name, created_by FROM chats WHERE id = $1',
            [chatId],
        );
        const row = result.rows[0];
        if (!row) return null;
        if (row.name) row.name = decryptText(row.name);
        return row;
    }

    static async getGroupMembers(chatId: string): Promise<GroupMember[]> {
        const query = `
            SELECT cp.user_id, cp.role, u.username, p.avatar_url
            FROM chat_participants cp
            JOIN users u ON u.id = cp.user_id
            LEFT JOIN profiles p ON p.user_id = u.id
            WHERE cp.chat_id = $1
            ORDER BY (cp.role = 'owner') DESC, u.username ASC`;
        const result = await pool.query(query, [chatId]);
        return result.rows.map((row: any) => decryptFields(row, ['avatar_url']));
    }

    static async isGroupOwner(chatId: string, userId: string): Promise<boolean> {
        const result = await pool.query(
            "SELECT 1 FROM chat_participants WHERE chat_id = $1 AND user_id = $2 AND role = 'owner'",
            [chatId, userId],
        );
        return (result.rowCount ?? 0) > 0;
    }

    static async addParticipant(chatId: string, userId: string): Promise<void> {
        await pool.query(
            "INSERT INTO chat_participants (chat_id, user_id, role) VALUES ($1, $2, 'member') ON CONFLICT (chat_id, user_id) DO NOTHING",
            [chatId, userId],
        );
    }

    // Full removal (not a soft-delete like 1:1 chat hiding) — used for both a
    // member leaving voluntarily and an owner removing/kicking someone.
    static async removeParticipant(chatId: string, userId: string): Promise<void> {
        await pool.query('DELETE FROM chat_participants WHERE chat_id = $1 AND user_id = $2', [chatId, userId]);
    }

    static async renameGroup(chatId: string, name: string): Promise<void> {
        await pool.query('UPDATE chats SET name = $2 WHERE id = $1', [chatId, encryptText(name)]);
    }

    // Distinct "other participant" ids across all this user's chats — used to
    // know who to notify live on profile/avatar changes.
    static async getContactIds(userId: string): Promise<string[]> {
        const query = `
            SELECT DISTINCT other_cp.user_id AS contact_id
            FROM chat_participants cp
            JOIN chat_participants other_cp ON cp.chat_id = other_cp.chat_id AND other_cp.user_id != $1
            WHERE cp.user_id = $1`;
        const result = await pool.query(query, [userId]);
        return result.rows.map((row: any) => row.contact_id);
    }

    static async getChatListForUser(userId: string): Promise<ChatListItem[]> {
        // Individual (1:1) chats join to the single other participant for their
        // username/avatar; group chats use the chat's own name/member count instead
        // (a plain join to "the other participant" wouldn't work — there can be many).
        const query = `
            SELECT 
                cp.chat_id,
                c.is_group,
                cp.is_archived,
                cp.is_muted,
                CASE WHEN c.is_group THEN NULL ELSE other.user_id END AS contact_id,
                CASE WHEN c.is_group THEN c.name ELSE other.username END AS contact_username,
                CASE WHEN c.is_group THEN NULL ELSE other.avatar_url END AS contact_avatar,
                member_count.cnt AS member_count,
                m.id AS last_message_id,
                m.content AS last_message_content,
                m.media_type AS last_message_type,
                m.status AS last_message_status,
                m.sender_id AS last_message_sender_id,
                m.created_at AS last_message_time,
                COALESCE(unread.unread_count, 0)::int AS unread_count
            FROM chat_participants cp
            JOIN chats c ON c.id = cp.chat_id
            LEFT JOIN LATERAL (
                SELECT ocp.user_id, u.username, p.avatar_url
                FROM chat_participants ocp
                JOIN users u ON u.id = ocp.user_id
                LEFT JOIN profiles p ON p.user_id = u.id
                WHERE ocp.chat_id = cp.chat_id AND ocp.user_id != $1 AND NOT c.is_group
                LIMIT 1
            ) other ON true
            LEFT JOIN LATERAL (
                SELECT COUNT(*)::int AS cnt FROM chat_participants mcp WHERE mcp.chat_id = cp.chat_id AND c.is_group
            ) member_count ON true
            LEFT JOIN LATERAL (
                SELECT id, content, media_type, status, sender_id, created_at 
                FROM messages 
                WHERE chat_id = cp.chat_id AND is_deleted = FALSE 
                ORDER BY created_at DESC 
                LIMIT 1
            ) m ON true
            LEFT JOIN LATERAL (
                SELECT COUNT(*) AS unread_count
                FROM messages msg2
                WHERE msg2.chat_id = cp.chat_id
                  AND msg2.sender_id != $1
                  AND msg2.is_deleted = FALSE
                  -- Per-participant read cursor: a message the reader (or anyone else in a
                  -- group) hasn't caught up to yet still counts as unread for them
                  -- specifically, regardless of whether other members have read it.
                  AND msg2.created_at > COALESCE(cp.last_read_at, '-infinity'::timestamp)
                  AND (cp.cleared_at IS NULL OR msg2.created_at > cp.cleared_at)
            ) unread ON true
            WHERE cp.user_id = $1 AND cp.is_deleted = FALSE
            ORDER BY m.created_at DESC NULLS LAST`;

        const result = await pool.query(query, [userId]);

        // Decrypt avatar URL and message preview unconditionally; contact_username is
        // only encrypted for group chats (it's the group's name) — a plain username
        // isn't encrypted, so decrypting it unconditionally would just spam
        // decryptText's "not in expected format" warning for every 1:1 chat.
        return result.rows.map((row: any) => {
            const decrypted = decryptFields(row, ['contact_avatar', 'last_message_content']);
            if (decrypted && decrypted.is_group && decrypted.contact_username) {
                decrypted.contact_username = decryptText(decrypted.contact_username);
            }
            return decrypted;
        });
    }

    static async setChatArchivedStatus(chatId: string, userId: string, isArchived: boolean): Promise<void> {
        const query = `
            UPDATE chat_participants 
            SET is_archived = $3 
            WHERE chat_id = $1 AND user_id = $2`;
        await pool.query(query, [chatId, userId, isArchived]);
    }

    static async setChatMutedStatus(chatId: string, userId: string, isMuted: boolean): Promise<void> {
        const query = `
            UPDATE chat_participants 
            SET is_muted = $3 
            WHERE chat_id = $1 AND user_id = $2`;
        await pool.query(query, [chatId, userId, isMuted]);
    }

    static async setChatDeletedStatus(chatId: string, userId: string, isDeleted: boolean): Promise<void> {
        // Deleting also stamps `cleared_at`, resetting the deleter's history so
        // they only see messages sent after this point (per-device delete, like WhatsApp).
        const query = isDeleted
            ? `UPDATE chat_participants 
               SET is_deleted = TRUE, cleared_at = NOW() 
               WHERE chat_id = $1 AND user_id = $2`
            : `UPDATE chat_participants 
               SET is_deleted = FALSE 
               WHERE chat_id = $1 AND user_id = $2`;
        await pool.query(query, [chatId, userId]);
    }

    // Un-hides a chat for anyone who'd archived/deleted/unfriended it — used on
    // new messages and when a re-accepted invite revives an old chat.
    static async reviveForAllParticipants(chatId: string): Promise<void> {
        const query = `
            UPDATE chat_participants 
            SET is_archived = FALSE, is_deleted = FALSE 
            WHERE chat_id = $1 AND (is_archived = TRUE OR is_deleted = TRUE)`;
        await pool.query(query, [chatId]);
    }

    // Hides the shared chat for both participants, but (unlike a manual delete)
    // leaves `cleared_at` untouched so history reappears if they reconnect.
    static async removeFriendship(chatId: string): Promise<void> {
        const query = `
            UPDATE chat_participants 
            SET is_deleted = TRUE, is_archived = FALSE 
            WHERE chat_id = $1`;
        await pool.query(query, [chatId]);
    }

    // Every other participant in the chat, plus their mute state and FCM token
    // — used to decide who to push a "new message" notification to.
    static async getOtherParticipantsForPush(
        chatId: string,
        excludeUserId: string,
    ): Promise<{ user_id: string; is_muted: boolean; fcm_token: string | null }[]> {
        const query = `
            SELECT cp.user_id, cp.is_muted, u.fcm_token
            FROM chat_participants cp
            JOIN users u ON u.id = cp.user_id
            WHERE cp.chat_id = $1 AND cp.user_id != $2`;
        const result = await pool.query(query, [chatId, excludeUserId]);
        return result.rows;
    }
}