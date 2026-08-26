import pool from '../config/database';
import { Message, MessageStatus, MediaType, MessageReplyPreview } from '../models/message.model';
import { encryptText, decryptText } from '../utils/encryption.util';

export class MessageRepository {
    static async saveMessage(
        chatId: string, 
        senderId: string, 
        content?: string, 
        mediaUrl?: string, 
        mediaType: MediaType = 'text',
        replyToId?: string | null,
    ): Promise<Message> {
        const encryptedContent = content ? encryptText(content) : null;
        const query = `
            INSERT INTO messages (chat_id, sender_id, content, media_url, media_type, status, reply_to_id) 
            VALUES ($1, $2, $3, $4, $5, 'sent', $6) 
            RETURNING *`;
        const result = await pool.query(query, [chatId, senderId, encryptedContent, mediaUrl, mediaType, replyToId || null]);
        const msg: Message = result.rows[0];
        if (msg.content) msg.content = decryptText(msg.content);
        if (msg.reply_to_id) {
            msg.reply_to = await MessageRepository.getReplyPreview(msg.reply_to_id);
        }
        return msg;
    }

    // Small, decrypted snapshot of the message being replied to, embedded on
    // the replying message so clients can render a quote inline.
    static async getReplyPreview(messageId: string): Promise<MessageReplyPreview | null> {
        const result = await pool.query(
            'SELECT id, sender_id, content, media_type, is_deleted FROM messages WHERE id = $1',
            [messageId],
        );
        const row = result.rows[0];
        if (!row) return null;
        return {
            id: row.id,
            sender_id: row.sender_id,
            content: row.is_deleted ? null : (row.content ? decryptText(row.content) : null),
            media_type: row.media_type,
            is_deleted: row.is_deleted,
        };
    }

    static async getMessagesForChat(chatId: string, userId: string): Promise<Message[]> {
        const query = `
            SELECT m.*,
                r.id AS r_id, r.sender_id AS r_sender_id, r.content AS r_content,
                r.media_type AS r_media_type, r.is_deleted AS r_is_deleted
            FROM messages m
            LEFT JOIN messages r ON m.reply_to_id = r.id
            LEFT JOIN chat_participants cp ON cp.chat_id = m.chat_id AND cp.user_id = $2
            WHERE m.chat_id = $1
              AND (cp.cleared_at IS NULL OR m.created_at > cp.cleared_at)
            ORDER BY m.created_at ASC`;
        const result = await pool.query(query, [chatId, userId]);

        return result.rows.map((row: any) => {
            const msg: Message = {
                id: row.id,
                chat_id: row.chat_id,
                sender_id: row.sender_id,
                content: row.content ? decryptText(row.content) : null,
                media_url: row.media_url,
                media_type: row.media_type,
                status: row.status,
                is_edited: row.is_edited,
                is_deleted: row.is_deleted,
                reply_to_id: row.reply_to_id,
                created_at: row.created_at,
            };
            if (row.r_id) {
                msg.reply_to = {
                    id: row.r_id,
                    sender_id: row.r_sender_id,
                    content: row.r_is_deleted ? null : (row.r_content ? decryptText(row.r_content) : null),
                    media_type: row.r_media_type,
                    is_deleted: row.r_is_deleted,
                };
            }
            return msg;
        });
    }

    static async updateMessageStatus(messageId: string, status: MessageStatus): Promise<void> {
        const query = 'UPDATE messages SET status = $2 WHERE id = $1';
        await pool.query(query, [messageId, status]);
    }

    static async markChatMessagesRead(chatId: string, userId: string): Promise<void> {
        const query = `
            UPDATE messages 
            SET status = 'read' 
            WHERE chat_id = $1 
              AND sender_id != $2 
              AND status != 'read' 
              AND is_deleted = FALSE`;
        await pool.query(query, [chatId, userId]);
    }

    static async editMessage(messageId: string, senderId: string, newContent: string): Promise<Message | null> {
        const encryptedContent = encryptText(newContent);
        const query = `
            UPDATE messages 
            SET content = $3, is_edited = TRUE 
            WHERE id = $1 AND sender_id = $2 AND is_deleted = FALSE 
            RETURNING *`;
        const result = await pool.query(query, [messageId, senderId, encryptedContent]);
        const msg: Message = result.rows[0];
        if (msg && msg.content) msg.content = decryptText(msg.content);
        return msg || null;
    }

    static async deleteMessage(messageId: string, senderId: string): Promise<Message | null> {
        const query = `
            UPDATE messages 
            SET is_deleted = TRUE, content = NULL, media_url = NULL 
            WHERE id = $1 AND sender_id = $2 
            RETURNING *`;
        const result = await pool.query(query, [messageId, senderId]);
        return result.rows[0] || null;
    }

    // Content is encrypted with a random IV per message (AES-256-CBC), so it can't
    // be filtered in SQL (e.g. ILIKE) — messages are decrypted first (reusing the
    // same chat history query/rules, including per-user cleared_at), then matched
    // in application code. Fine at this app's scale; would need a different
    // approach (e.g. a separate searchable index) if chat histories got huge.
    static async searchMessages(chatId: string, userId: string, query: string): Promise<Message[]> {
        const needle = query.toLowerCase();
        const all = await MessageRepository.getMessagesForChat(chatId, userId);
        return all.filter((m) => !m.is_deleted && m.content && m.content.toLowerCase().includes(needle));
    }
}