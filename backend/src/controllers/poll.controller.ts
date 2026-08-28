import { Request, Response } from 'express';
import { PollRepository } from '../repositories/poll.repository';
import { ChatRepository } from '../repositories/chat.repository';
import { getIO } from '../sockets/socket.instance';

const MAX_OPTIONS = 10;
const MIN_OPTIONS = 2;
const MAX_QUESTION_LENGTH = 300;
const MAX_OPTION_LENGTH = 100;

export class PollController {
    // 'voted_by_me' is per-requester, so a poll can't be broadcast as-is to a
    // whole room — fetch/emit a personalized copy to each participant's own room.
    private static async broadcastPollUpdate(
        pollId: string,
        chatId: string,
        actingUserId: string,
        actingUserPoll: unknown,
    ): Promise<void> {
        const io = getIO();
        if (!io) return;
        const participantIds = await ChatRepository.getParticipantIds(chatId);
        await Promise.all(participantIds.map(async (participantId) => {
            const personalizedPoll = participantId === actingUserId
                ? actingUserPoll
                : await PollRepository.getPollDetail(pollId, participantId);
            io.to(participantId).emit('poll_updated', personalizedPoll);
        }));
    }

    // Creates the poll's DB rows only; the client sends the actual chat message
    // via 'send_message' (mediaType: 'poll', mediaUrl: pollId), reusing its
    // existing broadcast/push/revive-chat logic.
    static async createPoll(req: Request, res: Response): Promise<void> {
        try {
            const userId = req.user!.userId;
            const { chatId, question, options, isAnonymous, allowMultipleAnswers } = req.body;

            if (typeof chatId !== 'string' || !chatId.trim()) {
                res.status(400).json({ error: 'A valid chatId is required.' });
                return;
            }
            if (!await ChatRepository.isUserInChat(chatId, userId)) {
                res.status(403).json({ error: 'You are not a participant in this chat.' });
                return;
            }

            const trimmedQuestion = (question ?? '').toString().trim();
            if (!trimmedQuestion) {
                res.status(400).json({ error: 'A poll question is required.' });
                return;
            }
            if (trimmedQuestion.length > MAX_QUESTION_LENGTH) {
                res.status(400).json({ error: `Poll question must be ${MAX_QUESTION_LENGTH} characters or fewer.` });
                return;
            }

            const trimmedOptions: string[] = Array.isArray(options)
                ? options.map((o: any) => (o ?? '').toString().trim()).filter((o: string) => o.length > 0)
                : [];
            if (trimmedOptions.length < MIN_OPTIONS || trimmedOptions.length > MAX_OPTIONS) {
                res.status(400).json({ error: `A poll needs between ${MIN_OPTIONS} and ${MAX_OPTIONS} options.` });
                return;
            }
            if (trimmedOptions.some((o) => o.length > MAX_OPTION_LENGTH)) {
                res.status(400).json({ error: `Each option must be ${MAX_OPTION_LENGTH} characters or fewer.` });
                return;
            }

            const pollId = await PollRepository.createPoll(
                chatId,
                userId,
                trimmedQuestion,
                trimmedOptions,
                !!isAnonymous,
                !!allowMultipleAnswers,
            );

            const poll = await PollRepository.getPollDetail(pollId, userId);
            res.status(201).json({ message: 'Poll created successfully.', pollId, poll });
        } catch (error) {
            res.status(500).json({ error: 'Failed to create poll.' });
        }
    }

    static async getPoll(req: Request, res: Response): Promise<void> {
        try {
            const userId = req.user!.userId;
            const pollId = req.params.pollId as string;

            const meta = await PollRepository.getPollMeta(pollId);
            if (!meta) {
                res.status(404).json({ error: 'Poll not found.' });
                return;
            }
            if (!await ChatRepository.isUserInChat(meta.chat_id, userId)) {
                res.status(403).json({ error: 'You are not a participant in this chat.' });
                return;
            }

            const poll = await PollRepository.getPollDetail(pollId, userId);
            res.status(200).json(poll);
        } catch (error) {
            res.status(500).json({ error: 'Failed to fetch poll.' });
        }
    }

    // Replaces the requester's vote(s) with the given option ids (an empty
    // array retracts their vote). Broadcasts the fresh tally to the chat room.
    static async vote(req: Request, res: Response): Promise<void> {
        try {
            const userId = req.user!.userId;
            const pollId = req.params.pollId as string;
            const { optionIds } = req.body;

            if (!Array.isArray(optionIds) || optionIds.some((id: any) => typeof id !== 'string')) {
                res.status(400).json({ error: 'optionIds must be an array of strings.' });
                return;
            }

            const meta = await PollRepository.getPollMeta(pollId);
            if (!meta) {
                res.status(404).json({ error: 'Poll not found.' });
                return;
            }
            if (!await ChatRepository.isUserInChat(meta.chat_id, userId)) {
                res.status(403).json({ error: 'You are not a participant in this chat.' });
                return;
            }
            if (meta.is_closed) {
                res.status(400).json({ error: 'This poll is closed.' });
                return;
            }
            if (!meta.allow_multiple_answers && optionIds.length > 1) {
                res.status(400).json({ error: 'This poll only allows a single choice.' });
                return;
            }

            const validOptionIds = await PollRepository.getOptionIds(pollId);
            const allValid = optionIds.every((id: string) => validOptionIds.includes(id));
            if (!allValid) {
                res.status(400).json({ error: 'One or more options are invalid for this poll.' });
                return;
            }

            await PollRepository.vote(pollId, userId, optionIds);

            const poll = await PollRepository.getPollDetail(pollId, userId);
            await PollController.broadcastPollUpdate(pollId, meta.chat_id, userId, poll);

            res.status(200).json(poll);
        } catch (error) {
            res.status(500).json({ error: 'Failed to record vote.' });
        }
    }

    // Creator-only: stops further voting on this poll.
    static async closePoll(req: Request, res: Response): Promise<void> {
        try {
            const userId = req.user!.userId;
            const pollId = req.params.pollId as string;

            const meta = await PollRepository.getPollMeta(pollId);
            if (!meta) {
                res.status(404).json({ error: 'Poll not found.' });
                return;
            }

            const closed = await PollRepository.closePoll(pollId, userId);
            if (!closed) {
                res.status(403).json({ error: 'Only the poll creator can close it.' });
                return;
            }

            const poll = await PollRepository.getPollDetail(pollId, userId);
            await PollController.broadcastPollUpdate(pollId, meta.chat_id, userId, poll);

            res.status(200).json(poll);
        } catch (error) {
            res.status(500).json({ error: 'Failed to close poll.' });
        }
    }
}
