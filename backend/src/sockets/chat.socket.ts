import { Server, Socket } from 'socket.io';
import jwt from 'jsonwebtoken';
import { MessageRepository } from '../repositories/message.repository';
import { ChatRepository } from '../repositories/chat.repository';
import { UserRepository } from '../repositories/user.repository';
import { SessionRepository } from '../repositories/session.repository';
import { PushService } from '../services/push.service';
import { JWT_SECRET } from '../config/env';
import { hasValidSession } from '../utils/session.util';
import { logger } from '../utils/logger.util';
import { MediaType } from '../models/message.model';
import type { AuthenticatedUser } from '../middleware/auth.middleware';

function buildMessagePreview(content: string | null | undefined, mediaType: string): string {
    switch (mediaType) {
        case 'image':
            return 'Sent a photo';
        case 'video':
            return 'Sent a video';
        case 'audio':
            return 'Sent a voice message';
        case 'poll':
            return `📊 Created a poll: ${(content || '').replace(/\s+/g, ' ').trim() || 'a poll'}`;
        default: {
            // One-line preview — the OS notification will further truncate/ellipsize
            // to whatever fits on screen, so we just strip newlines here.
            const flat = (content || '').replace(/\s+/g, ' ').trim();
            return flat || 'Sent a message';
        }
    }
}

export function registerChatHandlers(io: Server) {
    // Reject the connection up front unless it carries a valid JWT.
    io.use((socket: Socket, next) => {
        const token = socket.handshake.auth.token || socket.handshake.headers['authorization']?.split(' ')[1];
        
        if (!token) {
            return next(new Error('Authentication error: Token missing'));
        }

        jwt.verify(token, JWT_SECRET, (err: jwt.VerifyErrors | null, decoded: jwt.JwtPayload | string | undefined) => {
            if (err) {
                return next(new Error('Authentication error: Invalid or expired token'));
            }
            const user = decoded as AuthenticatedUser;
            // Reject a token whose specific session has been revoked (selectively logged
            // out, or logged out from that device) — see login()/auth.middleware.ts.
            hasValidSession(user).then((valid) => {
                if (!valid) {
                    return next(new Error('Authentication error: This session has been logged out'));
                }
                socket.data.user = user;
                next();
            }).catch(() => next(new Error('Authentication error: Could not verify session')));
        });
    });

    io.on('connection', (socket: Socket) => {
        const userId = socket.data.user.userId;
        const sessionId = socket.data.user.sessionId as string | undefined;
        logger.info(`User connected via WebSocket: ${userId}`);

        // Join a personal room for direct notifications (e.g., invites)
        socket.join(userId);

        // Join a per-session room so a selective logout of this specific device can
        // target only its sockets, without disconnecting the user's other sessions.
        if (sessionId) {
            socket.join(`session:${sessionId}`);
            SessionRepository.touchLastSeen(sessionId).catch((error) => {
                logger.error('Failed to update session last-seen timestamp:', error);
            });
        }

        // Join a specific chat room — only if the user is actually a
        // participant, otherwise anyone could join arbitrary chat rooms by ID.
        socket.on('join_chat', async (chatId: string) => {
            const isParticipant = await ChatRepository.isUserInChat(chatId, userId);
            if (!isParticipant) {
                socket.emit('error_feedback', { message: 'You are not a participant in this chat.' });
                return;
            }
            socket.join(chatId);
            logger.info(`User ${userId} joined chat room: ${chatId}`);
        });

        socket.on('send_message', async (data: { chatId: string; content?: string; mediaUrl?: string; mediaType?: MediaType; tempId?: string; replyToId?: string }) => {
            try {
                const { chatId, content, mediaUrl, mediaType, tempId, replyToId } = data;
                
                const savedMessage = await MessageRepository.saveMessage(
                    chatId, 
                    userId, 
                    content, 
                    mediaUrl, 
                    mediaType || 'text',
                    replyToId,
                );
                
                // Broadcast to the chat room; tempId is echoed back (not persisted) so the
                // sender can reconcile its optimistic message with the saved one.
                io.to(chatId).emit('receive_message', { ...savedMessage, tempId });

                // A new message un-archives/un-deletes the chat for anyone who'd
                // hidden it — it should stay hidden only until the next message arrives.
                await ChatRepository.reviveForAllParticipants(chatId);

                // Push-notify every other participant who isn't muted on this chat.
                try {
                    const [sender, otherParticipants] = await Promise.all([
                        UserRepository.getPushInfoById(userId),
                        ChatRepository.getOtherParticipantsForPush(chatId, userId),
                    ]);
                    const senderName = sender?.username || 'Someone';
                    const previewBody = buildMessagePreview(savedMessage.content, savedMessage.media_type);

                    for (const participant of otherParticipants) {
                        if (participant.is_muted || !participant.fcm_token) continue;
                        await PushService.sendToToken(participant.fcm_token, {
                            title: senderName,
                            body: previewBody,
                            data: {
                                type: 'message',
                                chatId,
                                contactId: userId,
                                contactName: senderName,
                            },
                        });
                    }
                } catch (pushError) {
                    logger.error('Failed to send message push notification:', pushError);
                }
            } catch (error) {
                // Echo tempId back so the sender can mark that message failed immediately,
                // instead of waiting for its client-side send timeout.
                socket.emit('error_feedback', { message: 'Failed to send message.', tempId: data.tempId });
            }
        });

        socket.on('typing', (data: { chatId: string; isTyping: boolean }) => {
            socket.to(data.chatId).emit('user_typing', { chatId: data.chatId, userId, isTyping: data.isTyping });
        });

        socket.on('update_message_status', async (data: { messageId: string; chatId: string; status: 'delivered' | 'read' }) => {
            try {
                await MessageRepository.updateMessageStatus(data.messageId, data.status);
                io.to(data.chatId).emit('message_status_updated', { messageId: data.messageId, status: data.status });
            } catch (error) {
                logger.error('Failed to update message status:', error);
            }
        });

        socket.on('edit_message', async (data: { messageId: string; chatId: string; newContent: string }) => {
            try {
                const updatedMessage = await MessageRepository.editMessage(data.messageId, userId, data.newContent);
                if (updatedMessage) {
                    io.to(data.chatId).emit('message_edited', updatedMessage);
                } else {
                    socket.emit('error_feedback', { message: 'Could not edit this message.' });
                }
            } catch (error) {
                socket.emit('error_feedback', { message: 'Failed to edit message.' });
            }
        });

        socket.on('delete_message', async (data: { messageId: string; chatId: string }) => {
            try {
                const deletedMessage = await MessageRepository.deleteMessage(data.messageId, userId);
                if (deletedMessage) {
                    io.to(data.chatId).emit('message_deleted', deletedMessage);
                } else {
                    socket.emit('error_feedback', { message: 'Could not delete this message.' });
                }
            } catch (error) {
                socket.emit('error_feedback', { message: 'Failed to delete message.' });
            }
        });

        socket.on('disconnect', () => {
            logger.info(`User disconnected: ${userId}`);
        });
    });
}