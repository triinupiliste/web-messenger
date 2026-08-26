export interface Poll {
    id: string;
    chat_id: string;
    creator_id: string | null;
    question: string; // Stored as encrypted text payload
    is_anonymous: boolean;
    allow_multiple_answers: boolean;
    is_closed: boolean;
    created_at: Date;
}

export interface PollOptionResult {
    id: string;
    option_text: string;
    position: number;
    vote_count: number;
    voted_by_me: boolean;
    // Only populated when the poll isn't anonymous; null otherwise.
    voter_usernames: string[] | null;
}

// The full shape returned to clients when fetching/creating/voting on a poll.
export interface PollDetail {
    id: string;
    chat_id: string;
    creator_id: string | null;
    question: string;
    is_anonymous: boolean;
    allow_multiple_answers: boolean;
    is_closed: boolean;
    created_at: Date;
    total_voters: number;
    options: PollOptionResult[];
}
