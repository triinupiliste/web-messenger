export type InviteStatus = 'pending' | 'accepted' | 'declined' | 'removed';

export interface Invite {
    id: string;
    sender_id: string;
    receiver_id: string;
    status: InviteStatus;
    chat_id?: string | null; // NULL for a 1:1 friend invite; set when inviting into an existing group chat
    created_at: Date;
}

// The other user's public-facing details attached to an enriched invite row
// (avatar_url is already decrypted by the time it's returned).
export interface InviteUserSummary {
    id: string;
    username: string;
    email: string;
    avatar_url: string | null;
}

// Present on an enriched invite row only when it's a group invite (chat_id is set).
export interface InviteGroupSummary {
    chat_id: string;
    name: string; // Decrypted group name
}

// Shape returned by InviteRepository.getPendingInvitesForUser/getIncomingInviteById.
export interface IncomingInviteItem {
    id: string;
    sender_id: string;
    status: InviteStatus;
    created_at: Date;
    sender: InviteUserSummary;
    group?: InviteGroupSummary | null;
}

// Shape returned by InviteRepository.getOutgoingInvitesForUser.
export interface OutgoingInviteItem {
    id: string;
    receiver_id: string;
    status: InviteStatus;
    created_at: Date;
    recipient: InviteUserSummary;
    group?: InviteGroupSummary | null;
}