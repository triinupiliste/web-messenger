import { Request, Response, NextFunction } from 'express';
import { InviteRepository } from '../repositories/invite.repository';
import { ChatRepository } from '../repositories/chat.repository';
import { UserRepository } from '../repositories/user.repository';
import { PushService } from '../services/push.service';
import { getIO } from '../sockets/socket.instance';
import { logger } from '../utils/logger.util';

export class InviteController {
    static async sendInvite(req: Request, res: Response, next: NextFunction): Promise<void> {
        try {
            const senderId = req.user!.userId;
            const { receiverId, chatId } = req.body;

            if (typeof receiverId !== 'string' || !receiverId.trim()) {
                res.status(400).json({ error: 'A valid receiverId is required.' });
                return;
            }

            if (senderId === receiverId) {
                res.status(400).json({ error: 'You cannot invite yourself.' });
                return;
            }

            if (!await UserRepository.existsById(receiverId)) {
                res.status(404).json({ error: 'The selected user no longer exists.' });
                return;
            }

            let groupChat: { id: string; is_group: boolean; name: string | null } | null = null;
            if (chatId) {
                if (typeof chatId !== 'string') {
                    res.status(400).json({ error: 'Invalid chatId.' });
                    return;
                }
                groupChat = await ChatRepository.getChatMeta(chatId);
                if (!groupChat || !groupChat.is_group) {
                    res.status(404).json({ error: 'Group chat not found.' });
                    return;
                }
                if (!await ChatRepository.isUserInChat(chatId, senderId)) {
                    res.status(403).json({ error: 'You are not a member of this group.' });
                    return;
                }
                if (await ChatRepository.isUserInChat(chatId, receiverId)) {
                    res.status(409).json({ error: 'That user is already a member of this group.' });
                    return;
                }
            }

            const existing = await InviteRepository.findExistingInvite(senderId, receiverId, chatId);
            if (existing) {
                res.status(409).json({
                    error: groupChat
                        ? 'An invite to this group is already pending for this user.'
                        : 'An invite or relationship already exists between these users.',
                });
                return;
            }

            const invite = await InviteRepository.createInvite(senderId, receiverId, chatId);
            res.status(201).json({ message: 'Chat invite sent successfully.', invite });

            // Let the receiver's Invites screen update live; emit the enriched shape
            // (with sender username/avatar, and group info if applicable) that the screen expects.
            const enrichedInvite = await InviteRepository.getIncomingInviteById(invite.id);
            getIO()?.to(receiverId).emit('new_invite', enrichedInvite ?? invite);

            // Push-notify the receiver — failures here must not affect the response above.
            try {
                const [sender, receiver] = await Promise.all([
                    UserRepository.getPushInfoById(senderId),
                    UserRepository.getPushInfoById(receiverId),
                ]);
                if (receiver?.fcm_token) {
                    await PushService.sendToToken(receiver.fcm_token, {
                        title: groupChat ? 'New group invite' : 'New chat invite',
                        body: groupChat
                            ? `${sender?.username || 'Someone'} invited you to join "${groupChat.name}"`
                            : `${sender?.username || 'Someone'} has sent you an invite`,
                        data: { type: 'invite' },
                    });
                }
            } catch (pushError) {
                logger.error('Failed to send invite push notification:', pushError);
            }
        } catch (error) {
            next(error);
        }
    }

    static async getPendingInvites(req: Request, res: Response, next: NextFunction): Promise<void> {
        try {
            const userId = req.user!.userId;
            const [incoming, outgoing] = await Promise.all([
                InviteRepository.getPendingInvitesForUser(userId),
                InviteRepository.getOutgoingInvitesForUser(userId),
            ]);
            res.status(200).json({ incoming, outgoing });
        } catch (error) {
            next(error);
        }
    }

    static async respondToInvite(req: Request, res: Response, next: NextFunction): Promise<void> {
        try {
            const userId = req.user!.userId;
            const { inviteId, status } = req.body; // status: 'accepted' or 'declined'

            if (!['accepted', 'declined'].includes(status)) {
                res.status(400).json({ error: 'Invalid response status.' });
                return;
            }

            const invite = await InviteRepository.findById(inviteId);
            if (!invite || invite.receiver_id !== userId) {
                res.status(404).json({ error: 'Invite not found.' });
                return;
            }

            const updated = await InviteRepository.updateInviteStatus(inviteId, status);

            if (status === 'accepted') {
                if (invite.chat_id) {
                    // Group invite: add the receiver as a member of the existing group chat.
                    await ChatRepository.addParticipant(invite.chat_id, userId);
                    getIO()?.to(invite.chat_id).emit('group_member_added', { chatId: invite.chat_id, userId });
                    getIO()?.to(userId).emit('group_member_added', { chatId: invite.chat_id, userId });
                } else {
                    // 1:1 invite: create a new chat — or revive the old one (with history)
                    // if they'd previously unfriended each other.
                    const existingChatId = await ChatRepository.findChatBetweenUsers(invite.sender_id, invite.receiver_id);
                    if (existingChatId) {
                        await ChatRepository.reviveForAllParticipants(existingChatId);
                    } else {
                        await ChatRepository.createChatBetweenUsers(invite.sender_id, invite.receiver_id);
                    }
                }
            }

            // Let the sender's Invites/Search screens update live if they're open.
            getIO()?.to(invite.sender_id).emit('invite_responded', updated);

            res.status(200).json({ message: `Invite ${status} successfully.`, invite: updated });
        } catch (error) {
            next(error);
        }
    }
}