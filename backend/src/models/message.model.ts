export type MessageStatus = 'sent' | 'delivered' | 'read';
export type MediaType = 'text' | 'image' | 'video' | 'audio' | 'poll';

// A lightweight snapshot of the message being replied to, embedded on the
// replying message so the client can render a quote without an extra fetch.
export interface MessageReplyPreview {
    id: string;
    sender_id: string;
    content: string | null;
    media_type: MediaType;
    is_deleted: boolean;
}

export interface Message {
    id: string;
    chat_id: string;
    sender_id: string;
    content?: string | null; // Stored as encrypted text payload
    media_url?: string | null;
    media_type: MediaType;
    status: MessageStatus;
    is_edited: boolean;
    is_deleted: boolean;
    reply_to_id?: string | null;
    reply_to?: MessageReplyPreview | null;
    created_at: Date;
}