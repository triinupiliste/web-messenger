export interface Chat {
    id: string;
    is_group: boolean;
    name?: string | null; // Decrypted group name; NULL for 1:1 chats
    created_by?: string | null;
    created_at: Date;
}

export type ChatParticipantRole = 'owner' | 'member';

export interface ChatParticipant {
    chat_id: string;
    user_id: string;
    role: ChatParticipantRole;
    is_archived: boolean;
    is_muted: boolean;
    is_deleted: boolean;
    cleared_at: Date | null;
}

// A single member row for the "Group Info" members list.
export interface GroupMember {
    user_id: string;
    username: string;
    avatar_url: string | null;
    role: ChatParticipantRole;
}

export interface ChatListItem {
    chat_id: string;
    is_group: boolean;
    contact_id: string | null; // NULL for group chats
    contact_username: string; // The other user's username for 1:1 chats, or the group name for group chats
    contact_avatar?: string | null; // Always NULL for group chats (no group avatar image)
    member_count?: number | null; // Only set for group chats
    is_archived: boolean;
    is_muted: boolean;
    last_message_id?: string | null;
    last_message_content?: string | null; // Decrypted content preview
    last_message_type?: string | null;
    last_message_status?: string | null;
    last_message_sender_id?: string | null;
    last_message_time?: Date | null;
    unread_count: number;
}