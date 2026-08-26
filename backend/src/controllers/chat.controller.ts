import { Request, Response } from 'express';
import { ChatRepository } from '../repositories/chat.repository';
import { MessageRepository } from '../repositories/message.repository';
import { InviteRepository } from '../repositories/invite.repository';
import { getIO } from '../sockets/socket.instance';

export class ChatController {
    static async getChatList(req: Request, res: Response): Promise<void> {
        try {
            const userId = req.user!.userId;
            const chats = await ChatRepository.getChatListForUser(userId);
            res.status(200).json(chats);
        } catch (error) {
            res.status(500).json({ error: 'Failed to fetch chat list.' });
        }
    }

    static async toggleArchiveChat(req: Request, res: Response): Promise<string | void> {
        try {
            const userId = req.user!.userId;
            const chatId = req.params.chatId as string;
            const { isArchived } = req.body;

            await ChatRepository.setChatArchivedStatus(chatId, userId, isArchived);
            res.status(200).json({ message: `Chat ${isArchived ? 'archived' : 'unarchived'} successfully.` });
        } catch (error) {
            res.status(500).json({ error: 'Failed to update chat archive state.' });
        }
    }

    static async toggleMuteChat(req: Request, res: Response): Promise<string | void> {
        try {
            const userId = req.user!.userId;
            const chatId = req.params.chatId as string;
            const { isMuted } = req.body;

            await ChatRepository.setChatMutedStatus(chatId, userId, isMuted);
            res.status(200).json({ message: `Chat ${isMuted ? 'muted' : 'unmuted'} successfully.` });
        } catch (error) {
            res.status(500).json({ error: 'Failed to update chat mute state.' });
        }
    }

    static async toggleDeleteChat(req: Request, res: Response): Promise<string | void> {
        try {
            const userId = req.user!.userId;
            const chatId = req.params.chatId as string;
            const { isDeleted } = req.body;

            await ChatRepository.setChatDeletedStatus(chatId, userId, isDeleted);
            res.status(200).json({ message: `Chat ${isDeleted ? 'deleted' : 'restored'} successfully.` });
        } catch (error) {
            res.status(500).json({ error: 'Failed to update chat delete state.' });
        }
    }

    // Ends the friendship: hides the chat for both participants, but (unlike a
    // manual delete) keeps history intact in case they reconnect later.
    static async removeFriend(req: Request, res: Response): Promise<string | void> {
        try {
            const userId = req.user!.userId;
            const chatId = req.params.chatId as string;

            const otherParticipants = await ChatRepository.getOtherParticipantsForPush(chatId, userId);
            const otherUserId = otherParticipants[0]?.user_id;
            if (!otherUserId) {
                res.status(404).json({ error: 'Chat not found.' });
                return;
            }

            await ChatRepository.removeFriendship(chatId);
            await InviteRepository.markRemovedBetween(userId, otherUserId);

            // Let the other participant's chat list update live if it's open.
            getIO()?.to(otherUserId).emit('friend_removed', { chatId });

            res.status(200).json({ message: 'Friend removed successfully.' });
        } catch (error) {
            res.status(500).json({ error: 'Failed to remove friend.' });
        }
    }

    static async getChatMessages(req: Request, res: Response): Promise<string | void> {
        try {
            const userId = req.user!.userId;
            const chatId = req.params.chatId as string;
            const messages = await MessageRepository.getMessagesForChat(chatId, userId);
            res.status(200).json(messages);
        } catch (error) {
            res.status(500).json({ error: 'Failed to fetch chat messages.' });
        }
    }

    static async markMessagesRead(req: Request, res: Response): Promise<void> {
        try {
            const userId = req.user!.userId;
            const chatId = req.params.chatId as string;
            await MessageRepository.markChatMessagesRead(chatId, userId);

            // Notify the other participant(s) in real time so their sent messages show as read.
            getIO()?.to(chatId).emit('messages_read', { chatId, readerId: userId });

            res.status(200).json({ message: 'Messages marked as read.' });
        } catch (error) {
            res.status(500).json({ error: 'Failed to mark messages as read.' });
        }
    }

    // Capped so a very common search term in a huge chat doesn't return an
    // unbounded payload; `total` tells the client if results were truncated.
    private static readonly MAX_SEARCH_RESULTS = 200;

    static async searchMessages(req: Request, res: Response): Promise<void> {
        try {
            const userId = req.user!.userId;
            const chatId = req.params.chatId as string;
            const query = (req.query.q ?? '').toString().trim();

            if (!query) {
                res.status(400).json({ error: 'A search query is required.' });
                return;
            }
            if (!await ChatRepository.isUserInChat(chatId, userId)) {
                res.status(403).json({ error: 'You are not a participant in this chat.' });
                return;
            }

            const matches = await MessageRepository.searchMessages(chatId, userId, query);
            const results = matches.slice(0, ChatController.MAX_SEARCH_RESULTS).map((m) => ({
                id: m.id,
                content: m.content,
                sender_id: m.sender_id,
                media_type: m.media_type,
                created_at: m.created_at,
            }));

            res.status(200).json({ results, total: matches.length });
        } catch (error) {
            res.status(500).json({ error: 'Failed to search messages.' });
        }
    }

    // --- Group chats ---

    // Creates a new group chat with just the requester as its owner; other
    // members are added afterwards via the invite system (see InviteController).
    static async createGroup(req: Request, res: Response): Promise<void> {
        try {
            const userId = req.user!.userId;
            const name = (req.body?.name ?? '').toString().trim();

            if (!name) {
                res.status(400).json({ error: 'A group name is required.' });
                return;
            }
            if (name.length > 100) {
                res.status(400).json({ error: 'Group name must be 100 characters or fewer.' });
                return;
            }

            const chatId = await ChatRepository.createGroupChat(userId, name);
            res.status(201).json({ message: 'Group created successfully.', chatId });
        } catch (error) {
            res.status(500).json({ error: 'Failed to create group.' });
        }
    }

    static async getGroupMembers(req: Request, res: Response): Promise<void> {
        try {
            const userId = req.user!.userId;
            const chatId = req.params.chatId as string;

            if (!await ChatRepository.isUserInChat(chatId, userId)) {
                res.status(403).json({ error: 'You are not a participant in this chat.' });
                return;
            }

            const members = await ChatRepository.getGroupMembers(chatId);
            res.status(200).json(members);
        } catch (error) {
            res.status(500).json({ error: 'Failed to fetch group members.' });
        }
    }

    // Removes a member from a group: any member can remove themselves (leave),
    // but only the owner can remove someone else, and the owner can't be removed.
    static async removeMember(req: Request, res: Response): Promise<void> {
        try {
            const userId = req.user!.userId;
            const chatId = req.params.chatId as string;
            const targetUserId = req.params.userId as string;

            const chat = await ChatRepository.getChatMeta(chatId);
            if (!chat || !chat.is_group) {
                res.status(404).json({ error: 'Group chat not found.' });
                return;
            }

            const isSelf = targetUserId === userId;
            if (!isSelf) {
                const requesterIsOwner = await ChatRepository.isGroupOwner(chatId, userId);
                if (!requesterIsOwner) {
                    res.status(403).json({ error: 'Only the group owner can remove other members.' });
                    return;
                }
                if (chat.created_by === targetUserId) {
                    res.status(400).json({ error: 'The group owner cannot be removed.' });
                    return;
                }
            }

            await ChatRepository.removeParticipant(chatId, targetUserId);

            getIO()?.to(chatId).emit('group_member_removed', { chatId, userId: targetUserId, removedBySelf: isSelf });
            getIO()?.to(targetUserId).emit('group_member_removed', { chatId, userId: targetUserId, removedBySelf: isSelf });

            res.status(200).json({ message: isSelf ? 'Left the group.' : 'Member removed.' });
        } catch (error) {
            res.status(500).json({ error: 'Failed to remove group member.' });
        }
    }

    // Owner-only: renames the group chat.
    static async renameGroup(req: Request, res: Response): Promise<void> {
        try {
            const userId = req.user!.userId;
            const chatId = req.params.chatId as string;
            const name = (req.body?.name ?? '').toString().trim();

            if (!name) {
                res.status(400).json({ error: 'A group name is required.' });
                return;
            }
            if (name.length > 100) {
                res.status(400).json({ error: 'Group name must be 100 characters or fewer.' });
                return;
            }

            const chat = await ChatRepository.getChatMeta(chatId);
            if (!chat || !chat.is_group) {
                res.status(404).json({ error: 'Group chat not found.' });
                return;
            }
            if (chat.created_by !== userId) {
                res.status(403).json({ error: 'Only the group owner can rename the group.' });
                return;
            }

            await ChatRepository.renameGroup(chatId, name);

            getIO()?.to(chatId).emit('group_renamed', { chatId, name });

            res.status(200).json({ message: 'Group renamed successfully.' });
        } catch (error) {
            res.status(500).json({ error: 'Failed to rename group.' });
        }
    }
}