import pool from '../config/database';
import { IncomingInviteItem, Invite, InviteStatus, InviteUserSummary, OutgoingInviteItem } from '../models/invite.model';
import { decryptFields, decryptText } from '../utils/encryption.util';

// Raw joined row shared by getPendingInvitesForUser/getIncomingInviteById/
// getOutgoingInvitesForUser, before decrypting the nested user summary and
// resolving the group_name/chat_id pair into a `group` object.
interface EnrichedInviteRow {
    id: string;
    sender_id?: string;
    receiver_id?: string;
    status: InviteStatus;
    created_at: Date;
    chat_id: string | null;
    sender?: InviteUserSummary;
    recipient?: InviteUserSummary;
    group_name: string | null;
}

export class InviteRepository {
    static async createInvite(senderId: string, receiverId: string, chatId?: string | null): Promise<Invite> {
        const query = `
            INSERT INTO invites (sender_id, receiver_id, status, chat_id) 
            VALUES ($1, $2, 'pending', $3) 
            RETURNING *`;
        const result = await pool.query(query, [senderId, receiverId, chatId || null]);
        return result.rows[0];
    }

    // For a 1:1 invite (chatId omitted): blocks a duplicate friend invite/relationship.
    // For a group invite (chatId given): only blocks a duplicate *pending* invite to
    // that specific group — the same two users can otherwise have any number of
    // separate group invites between them, and being friends elsewhere doesn't matter.
    static async findExistingInvite(senderId: string, receiverId: string, chatId?: string | null): Promise<Invite | null> {
        const query = chatId
            ? `SELECT * FROM invites 
               WHERE sender_id = $1 AND receiver_id = $2 AND chat_id = $3 AND status = 'pending'`
            : `SELECT * FROM invites 
               WHERE ((sender_id = $1 AND receiver_id = $2) 
                   OR (sender_id = $2 AND receiver_id = $1))
                 AND status IN ('pending', 'accepted')
                 AND chat_id IS NULL`;
        const params = chatId ? [senderId, receiverId, chatId] : [senderId, receiverId];
        const result = await pool.query(query, params);
        return result.rows[0] || null;
    }

    static async getPendingInvitesForUser(userId: string): Promise<IncomingInviteItem[]> {
        const query = `
            SELECT i.id, i.sender_id, i.status, i.created_at, i.chat_id,
                   json_build_object(
                       'id', u.id,
                       'username', u.username,
                       'email', u.email,
                       'avatar_url', p.avatar_url
                   ) AS sender,
                   c.name AS group_name
            FROM invites i
            JOIN users u ON i.sender_id = u.id
            LEFT JOIN profiles p ON u.id = p.user_id
            LEFT JOIN chats c ON c.id = i.chat_id
            WHERE i.receiver_id = $1 AND i.status = 'pending'
            ORDER BY i.created_at DESC`;
        const result = await pool.query(query, [userId]);
        return result.rows.map((row: EnrichedInviteRow) => InviteRepository._enrichIncomingRow(row));
    }

    // Same shape as getPendingInvitesForUser, for a single invite — used to
    // emit a fully-enriched 'new_invite' socket payload right when it's created.
    static async getIncomingInviteById(inviteId: string): Promise<IncomingInviteItem | null> {
        const query = `
            SELECT i.id, i.sender_id, i.status, i.created_at, i.chat_id,
                   json_build_object(
                       'id', u.id,
                       'username', u.username,
                       'email', u.email,
                       'avatar_url', p.avatar_url
                   ) AS sender,
                   c.name AS group_name
            FROM invites i
            JOIN users u ON i.sender_id = u.id
            LEFT JOIN profiles p ON u.id = p.user_id
            LEFT JOIN chats c ON c.id = i.chat_id
            WHERE i.id = $1`;
        const result = await pool.query(query, [inviteId]);
        const row = result.rows[0];
        if (!row) return null;
        return InviteRepository._enrichIncomingRow(row);
    }

    static async getOutgoingInvitesForUser(userId: string): Promise<OutgoingInviteItem[]> {
        const query = `
            SELECT i.id, i.receiver_id, i.status, i.created_at, i.chat_id,
                   json_build_object(
                       'id', u.id,
                       'username', u.username,
                       'email', u.email,
                       'avatar_url', p.avatar_url
                   ) AS recipient,
                   c.name AS group_name
            FROM invites i
            JOIN users u ON i.receiver_id = u.id
            LEFT JOIN profiles p ON u.id = p.user_id
            LEFT JOIN chats c ON c.id = i.chat_id
            WHERE i.sender_id = $1 AND i.status = 'pending'
            ORDER BY i.created_at DESC`;
        const result = await pool.query(query, [userId]);
        return result.rows.map((row: EnrichedInviteRow) => {
            const { group_name, chat_id, ...rest } = row;
            return {
                ...rest,
                recipient: decryptFields({ ...row.recipient }, ['email', 'avatar_url']),
                group: chat_id ? { chat_id, name: group_name ? decryptText(group_name) : '' } : null,
            } as OutgoingInviteItem;
        });
    }

    // Shared by getPendingInvitesForUser/getIncomingInviteById: decrypts the
    // sender's fields and, if this is a group invite, attaches the decrypted group name.
    private static _enrichIncomingRow(row: EnrichedInviteRow): IncomingInviteItem {
        const { group_name, chat_id, ...rest } = row;
        return {
            ...rest,
            sender: decryptFields({ ...row.sender }, ['email', 'avatar_url']),
            group: chat_id ? { chat_id, name: group_name ? decryptText(group_name) : '' } : null,
        } as IncomingInviteItem;
    }

    static async updateInviteStatus(inviteId: string, status: InviteStatus): Promise<Invite | null> {
        const query = `
            UPDATE invites SET status = $2 
            WHERE id = $1 
            RETURNING *`;
        const result = await pool.query(query, [inviteId, status]);
        return result.rows[0] || null;
    }

    // Downgrades the invite that made them friends so it no longer blocks a
    // fresh invite via findExistingInvite's "already exists" check.
    static async markRemovedBetween(user1Id: string, user2Id: string): Promise<void> {
        const query = `
            UPDATE invites SET status = 'removed'
            WHERE status = 'accepted'
              AND ((sender_id = $1 AND receiver_id = $2)
                OR (sender_id = $2 AND receiver_id = $1))`;
        await pool.query(query, [user1Id, user2Id]);
    }

    static async findById(inviteId: string): Promise<Invite | null> {
        const query = 'SELECT * FROM invites WHERE id = $1';
        const result = await pool.query(query, [inviteId]);
        return result.rows[0] || null;
    }

    // User ids with a pending invite (sender or receiver) — used alongside
    // getContactIds so profile/avatar changes reflect live on invite screens.
    static async getPendingInvitePartnerIds(userId: string): Promise<string[]> {
        const query = `
            SELECT DISTINCT
                CASE WHEN sender_id = $1 THEN receiver_id ELSE sender_id END AS partner_id
            FROM invites
            WHERE (sender_id = $1 OR receiver_id = $1) AND status = 'pending'`;
        const result = await pool.query(query, [userId]);
        return result.rows.map((row: { partner_id: string }) => row.partner_id);
    }
}