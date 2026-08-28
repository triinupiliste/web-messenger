import { Request, Response } from 'express';
import { UserRepository } from '../repositories/user.repository';
import { ChatRepository } from '../repositories/chat.repository';
import { InviteRepository } from '../repositories/invite.repository';
import { isValidEmail } from '../utils/validator.util';
import { getIO } from '../sockets/socket.instance';
import { logger } from '../utils/logger.util';

export class UserController {
    static async getProfile(req: Request, res: Response): Promise<void> {
        try {
            const userId = req.user!.userId;
            const profile = await UserRepository.getProfile(userId);
            if (!profile) {
                res.status(404).json({ error: 'Profile not found.' });
                return;
            }
            res.status(200).json(profile);
        } catch (error) {
            res.status(500).json({ error: 'Failed to fetch user profile.' });
        }
    }

    static async updateProfile(req: Request, res: Response): Promise<void> {
        try {
            const userId = req.user!.userId;
            const { avatar_url, about_me, username, email } = req.body;

            let normalizedUsername: string | undefined;
            let normalizedEmail: string | undefined;

            if (username !== undefined) {
                normalizedUsername = typeof username === 'string' ? username.trim() : '';
                if (!normalizedUsername) {
                    res.status(400).json({ error: 'Username cannot be empty.', field: 'username' });
                    return;
                }
            }

            if (email !== undefined) {
                normalizedEmail = typeof email === 'string' ? email.trim().toLowerCase() : '';
                if (!isValidEmail(normalizedEmail)) {
                    res.status(400).json({ error: 'Invalid email format.', field: 'email' });
                    return;
                }
            }

            // Enforce the same email/username uniqueness constraints as registration
            // when either field changes.
            if (normalizedUsername !== undefined || normalizedEmail !== undefined) {
                const existingUser = await UserRepository.findByEmailOrUsernameExcludingUser(
                    normalizedEmail ?? '',
                    normalizedUsername ?? '',
                    userId,
                );
                if (existingUser) {
                    if (normalizedEmail && existingUser.email.toLowerCase() === normalizedEmail) {
                        res.status(409).json({ error: 'Email is already in use.', field: 'email' });
                        return;
                    }
                    if (normalizedUsername && existingUser.username === normalizedUsername) {
                        res.status(409).json({ error: 'Username is already in use.', field: 'username' });
                        return;
                    }
                }
            }

            const updatedProfile = await UserRepository.updateProfile(userId, {
                username: normalizedUsername,
                email: normalizedEmail,
                avatarUrl: avatar_url,
                aboutMe: about_me,
            });

            // Let contacts and pending-invite partners see the new username/avatar
            // live, without reopening the chat list/invites/search screens. Also
            // notify this same account's other active sessions (e.g. phone app
            // while editing from the browser) so their profile screen updates
            // without needing a restart.
            const [contactIds, invitePartnerIds] = await Promise.all([
                ChatRepository.getContactIds(userId),
                InviteRepository.getPendingInvitePartnerIds(userId),
            ]);
            const notifyIds = new Set([...contactIds, ...invitePartnerIds, userId]);
            const payload = {
                userId,
                username: updatedProfile.username,
                avatar_url: updatedProfile.avatar_url,
                about_me: updatedProfile.about_me,
            };
            for (const id of notifyIds) {
                getIO()?.to(id).emit('profile_updated', payload);
            }

            res.status(200).json({ message: 'Profile updated successfully', profile: updatedProfile });
        } catch (error) {
            res.status(500).json({ error: 'Failed to update profile.' });
        }
    }


    // Used by the "View Profile" option in a chat's overflow menu.
    static async getUserById(req: Request, res: Response): Promise<void> {
        try {
            const { userId } = req.params;
            const profile = await UserRepository.getProfile(userId);
            if (!profile) {
                res.status(404).json({ error: 'User not found.' });
                return;
            }
            res.status(200).json(profile);
        } catch (error) {
            res.status(500).json({ error: 'Failed to fetch user profile.' });
        }
    }

    static async searchUsers(req: Request, res: Response): Promise<void> {
        try {
            const tokenUser = req.user;
            const currentUserId = tokenUser?.userId;
            const searchTerm = req.query.q as string;

            if (!searchTerm) {
                res.status(400).json({ error: 'Search query parameter "q" is required.' });
                return;
            }

            if (!currentUserId) {
                res.status(401).json({ error: 'Unauthorized user identification.' });
                return;
            }

            const users = await UserRepository.searchUsers(searchTerm, currentUserId);
            res.status(200).json(users);
        } catch (error) {
            logger.error('Search error:', error);
            res.status(500).json({ error: 'Failed to search users.' });
        }
    }

    // Lets the backend push notifications (new messages, invites) to this device.
    static async updateFcmToken(req: Request, res: Response): Promise<void> {
        try {
            const userId = req.user!.userId;
            const { fcmToken } = req.body;

            if (!fcmToken || typeof fcmToken !== 'string') {
                res.status(400).json({ error: 'fcmToken is required.' });
                return;
            }

            await UserRepository.updateFcmToken(userId, fcmToken);
            res.status(200).json({ message: 'FCM token saved.' });
        } catch (error) {
            res.status(500).json({ error: 'Failed to save FCM token.' });
        }
    }
}