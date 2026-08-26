import pool from '../config/database';
import { Poll, PollDetail, PollOptionResult } from '../models/poll.model';
import { decryptText, encryptText } from '../utils/encryption.util';

export class PollRepository {
    // Creates a poll and its options in one transaction; returns the new poll's id.
    static async createPoll(
        chatId: string,
        creatorId: string,
        question: string,
        options: string[],
        isAnonymous: boolean,
        allowMultipleAnswers: boolean,
    ): Promise<string> {
        const client = await pool.connect();
        try {
            await client.query('BEGIN');
            const pollResult = await client.query(
                `INSERT INTO polls (chat_id, creator_id, question, is_anonymous, allow_multiple_answers)
                 VALUES ($1, $2, $3, $4, $5)
                 RETURNING id`,
                [chatId, creatorId, encryptText(question), isAnonymous, allowMultipleAnswers],
            );
            const pollId = pollResult.rows[0].id;

            for (let i = 0; i < options.length; i++) {
                await client.query(
                    'INSERT INTO poll_options (poll_id, option_text, position) VALUES ($1, $2, $3)',
                    [pollId, encryptText(options[i]), i],
                );
            }

            await client.query('COMMIT');
            return pollId;
        } catch (error) {
            await client.query('ROLLBACK');
            throw error;
        } finally {
            client.release();
        }
    }

    // Lightweight lookup used to authorize/validate before voting or closing,
    // without paying for the full tally query below.
    static async getPollMeta(pollId: string): Promise<Poll | null> {
        const result = await pool.query('SELECT * FROM polls WHERE id = $1', [pollId]);
        const row = result.rows[0];
        if (!row) return null;
        if (row.question) row.question = decryptText(row.question);
        return row;
    }

    // Full poll detail: question, options with vote tallies, whether
    // requestingUserId voted for each, and (non-anonymous polls only) the
    // list of voter usernames per option.
    static async getPollDetail(pollId: string, requestingUserId: string): Promise<PollDetail | null> {
        const poll = await PollRepository.getPollMeta(pollId);
        if (!poll) return null;

        const optionsQuery = `
            SELECT 
                po.id,
                po.option_text,
                po.position,
                COUNT(pv.user_id)::int AS vote_count,
                COALESCE(BOOL_OR(pv.user_id = $2), FALSE) AS voted_by_me,
                CASE WHEN $3 THEN NULL ELSE (
                    SELECT json_agg(u.username ORDER BY u.username)
                    FROM poll_votes pv2
                    JOIN users u ON u.id = pv2.user_id
                    WHERE pv2.option_id = po.id
                ) END AS voter_usernames
            FROM poll_options po
            LEFT JOIN poll_votes pv ON pv.option_id = po.id
            WHERE po.poll_id = $1
            GROUP BY po.id, po.option_text, po.position
            ORDER BY po.position ASC`;
        const optionsResult = await pool.query(optionsQuery, [pollId, requestingUserId, poll.is_anonymous]);

        const options: PollOptionResult[] = optionsResult.rows.map((row: any) => ({
            id: row.id,
            option_text: decryptText(row.option_text),
            position: row.position,
            vote_count: row.vote_count,
            voted_by_me: row.voted_by_me,
            voter_usernames: row.voter_usernames,
        }));

        const totalVotersResult = await pool.query(
            'SELECT COUNT(DISTINCT user_id)::int AS cnt FROM poll_votes WHERE poll_id = $1',
            [pollId],
        );

        return {
            id: poll.id,
            chat_id: poll.chat_id,
            creator_id: poll.creator_id,
            question: poll.question,
            is_anonymous: poll.is_anonymous,
            allow_multiple_answers: poll.allow_multiple_answers,
            is_closed: poll.is_closed,
            created_at: poll.created_at,
            total_voters: totalVotersResult.rows[0].cnt,
            options,
        };
    }

    // Returns the ids of the given poll's options, for validating that vote
    // requests only reference options that actually belong to this poll.
    static async getOptionIds(pollId: string): Promise<string[]> {
        const result = await pool.query('SELECT id FROM poll_options WHERE poll_id = $1', [pollId]);
        return result.rows.map((row: any) => row.id);
    }

    // Replaces this user's vote(s) on the poll with the given option ids
    // (an empty array retracts their vote entirely).
    static async vote(pollId: string, userId: string, optionIds: string[]): Promise<void> {
        const client = await pool.connect();
        try {
            await client.query('BEGIN');
            await client.query('DELETE FROM poll_votes WHERE poll_id = $1 AND user_id = $2', [pollId, userId]);
            for (const optionId of optionIds) {
                await client.query(
                    'INSERT INTO poll_votes (poll_id, option_id, user_id) VALUES ($1, $2, $3)',
                    [pollId, optionId, userId],
                );
            }
            await client.query('COMMIT');
        } catch (error) {
            await client.query('ROLLBACK');
            throw error;
        } finally {
            client.release();
        }
    }

    // Owner-only; returns true if the poll existed and was closed by this call.
    static async closePoll(pollId: string, requesterId: string): Promise<boolean> {
        const result = await pool.query(
            'UPDATE polls SET is_closed = TRUE WHERE id = $1 AND creator_id = $2 RETURNING id',
            [pollId, requesterId],
        );
        return (result.rowCount ?? 0) > 0;
    }
}
