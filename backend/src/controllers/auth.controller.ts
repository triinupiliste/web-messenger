import { Request, Response } from 'express';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import { createHash, randomBytes } from 'crypto';
import { UserRepository } from '../repositories/user.repository';
import { SessionRepository } from '../repositories/session.repository';
import { validatePasswordStrength, isValidEmail } from '../utils/validator.util';
import { sendVerificationEmail, sendPasswordResetEmail } from '../services/email.service';
import { JWT_SECRET } from '../config/env';
import { getIO } from '../sockets/socket.instance';
import { verificationPage, resetPasswordPage } from '../services/auth-pages.service';
import { logger } from '../utils/logger.util';
import {
    VERIFICATION_TOKEN_LIFETIME_MS,
    RESET_TOKEN_LIFETIME_MS,
    BCRYPT_SALT_ROUNDS,
} from '../config/constants';

function createVerificationToken(): { rawToken: string; tokenHash: string; expiresAt: Date } {
    const rawToken = randomBytes(32).toString('hex');
    return {
        rawToken,
        tokenHash: createHash('sha256').update(rawToken).digest('hex'),
        expiresAt: new Date(Date.now() + VERIFICATION_TOKEN_LIFETIME_MS),
    };
}

function createResetToken(): { rawToken: string; tokenHash: string; expiresAt: Date } {
    const rawToken = randomBytes(32).toString('hex');
    return {
        rawToken,
        tokenHash: createHash('sha256').update(rawToken).digest('hex'),
        expiresAt: new Date(Date.now() + RESET_TOKEN_LIFETIME_MS),
    };
}

export class AuthController {
    static async register(req: Request, res: Response): Promise<void> {
        try {
            const { email, username, password } = req.body;

            const normalizedEmail = typeof email === 'string' ? email.trim().toLowerCase() : '';
            const normalizedUsername = typeof username === 'string' ? username.trim() : '';

            if (!isValidEmail(normalizedEmail)) {
                res.status(400).json({ error: 'Invalid email format.' });
                return;
            }

            const passwordCheck = validatePasswordStrength(password);
            if (!passwordCheck.isValid) {
                res.status(400).json({ error: 'Password does not meet strength requirements.', details: passwordCheck.errors });
                return;
            }

            const existingUser = await UserRepository.findByEmailOrUsername(
                normalizedEmail,
                normalizedUsername,
            );
            if (existingUser) {
                if (existingUser.email.toLowerCase() === normalizedEmail) {
                    res.status(409).json({ error: 'Email is already in use.', field: 'email' });
                    return;
                }
                if (existingUser.username === normalizedUsername) {
                    res.status(409).json({ error: 'Username is already in use.', field: 'username' });
                    return;
                }
            }

            const salt = await bcrypt.genSalt(BCRYPT_SALT_ROUNDS);
            const passwordHash = await bcrypt.hash(password, salt);
            const verification = createVerificationToken();

            const newUser = await UserRepository.createUser(
                normalizedEmail,
                normalizedUsername,
                passwordHash,
                verification.tokenHash,
                verification.expiresAt,
            );

            let verificationEmailSent = true;
            try {
                await sendVerificationEmail({
                    to: newUser.email,
                    username: newUser.username,
                    token: verification.rawToken,
                });
            } catch (emailError) {
                verificationEmailSent = false;
                logger.error('Failed to send verification email:', emailError);
            }

            res.status(201).json({
                message: verificationEmailSent
                    ? 'Account created successfully. Please verify your email.'
                    : 'Account created, but the verification email could not be sent. Please request a new one.',
                verificationEmailSent,
                user: { id: newUser.id, email: newUser.email, username: newUser.username },
            });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error during registration.' });
        }
    }

    static async login(req: Request, res: Response): Promise<void> {
        try {
            const { email, password } = req.body;
            const normalizedEmail = typeof email === 'string' ? email.trim().toLowerCase() : '';
            const user = await UserRepository.findByEmailOrUsername(normalizedEmail, '');
            if (!user) {
                res.status(404).json({
                    error: 'No account is registered with this email.',
                    code: 'ACCOUNT_NOT_FOUND',
                });
                return;
            }

            const isMatch = await bcrypt.compare(password, user.password_hash);
            if (!isMatch) {
                res.status(401).json({ error: 'Invalid email or password.' });
                return;
            }

            if (!user.is_verified) {
                res.status(403).json({
                    error: 'Please verify your email before logging in.',
                    code: 'EMAIL_NOT_VERIFIED',
                });
                return;
            }

            // Creates a new, independent session for this device/browser. Other
            // sessions (e.g. the mobile app, or another browser) are left untouched,
            // so the same account can be logged in from multiple places at once.
            const platform = typeof req.body.platform === 'string' && req.body.platform.trim()
                ? req.body.platform.trim().slice(0, 20)
                : 'mobile';
            const deviceName = typeof req.body.deviceName === 'string' && req.body.deviceName.trim()
                ? req.body.deviceName.trim().slice(0, 255)
                : null;
            const session = await SessionRepository.create(user.id, platform, deviceName);
            const token = jwt.sign(
                { userId: user.id, email: user.email, sessionId: session.id },
                JWT_SECRET,
                { expiresIn: '7d' },
            );

            res.status(200).json({
                message: 'Login successful',
                token,
                user: { id: user.id, email: user.email, username: user.username },
                session: { id: session.id, platform: session.platform, deviceName: session.device_name },
            });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error during login.' });
        }
    }

    static async verifyEmail(req: Request, res: Response): Promise<void> {
        const rawToken = typeof req.query.token === 'string' ? req.query.token : '';
        if (!rawToken) {
            res.status(400).send(verificationPage(
                'Invalid verification link',
                'The verification token is missing.',
                false,
            ));
            return;
        }

        try {
            const tokenHash = createHash('sha256').update(rawToken).digest('hex');
            const user = await UserRepository.verifyEmail(tokenHash);
            if (!user) {
                res.status(400).send(verificationPage(
                    'Link invalid or expired',
                    'Request a new verification email and try again.',
                    false,
                ));
                return;
            }

            res.status(200).send(verificationPage(
                'Email verified',
                'Your account has been verified successfully.',
                true,
            ));
        } catch (error) {
            logger.error('Email verification failed:', error);
            res.status(500).send(verificationPage(
                'Verification failed',
                'Something went wrong. Please try again later.',
                false,
            ));
        }
    }

    static async resendVerificationEmail(req: Request, res: Response): Promise<void> {
        try {
            const email = typeof req.body.email === 'string'
                ? req.body.email.trim().toLowerCase()
                : '';
            const genericMessage = 'If an unverified account exists, a verification email has been sent.';

            if (!isValidEmail(email)) {
                res.status(400).json({ error: 'Invalid email format.' });
                return;
            }

            const user = await UserRepository.findByEmailOrUsername(email, '');
            if (!user || user.is_verified) {
                res.status(200).json({ message: genericMessage });
                return;
            }

            const verification = createVerificationToken();
            await UserRepository.setVerificationToken(
                user.id,
                verification.tokenHash,
                verification.expiresAt,
            );
            await sendVerificationEmail({
                to: user.email,
                username: user.username,
                token: verification.rawToken,
            });

            res.status(200).json({ message: genericMessage });
        } catch (error) {
            logger.error('Resending verification email failed:', error);
            res.status(502).json({ error: 'Unable to send verification email right now.' });
        }
    }

    static async requestPasswordReset(req: Request, res: Response): Promise<void> {
        // Always respond with the same generic message, regardless of whether the
        // email exists, so this endpoint can't be used to enumerate accounts.
        const genericMessage = 'If an account with that email exists, a password reset link has been sent.';

        try {
            const email = typeof req.body.email === 'string'
                ? req.body.email.trim().toLowerCase()
                : '';

            if (!isValidEmail(email)) {
                res.status(400).json({ error: 'Invalid email format.' });
                return;
            }

            const user = await UserRepository.findByEmailOrUsername(email, '');
            if (user) {
                const reset = createResetToken();
                await UserRepository.setResetToken(user.id, reset.tokenHash, reset.expiresAt);
                try {
                    await sendPasswordResetEmail({
                        to: user.email,
                        username: user.username,
                        token: reset.rawToken,
                    });
                } catch (emailError) {
                    logger.error('Failed to send password reset email:', emailError);
                }
            }

            res.status(200).json({ message: genericMessage });
        } catch (error) {
            logger.error('Password reset request failed:', error);
            res.status(500).json({ error: 'Unable to process password reset request right now.' });
        }
    }

    static async resetPassword(req: Request, res: Response): Promise<void> {
        // GET renders an HTML form (opened from the email link); POST handles both
        // that form submission and direct JSON calls from the mobile app.
        if (req.method === 'GET') {
            const rawToken = typeof req.query.token === 'string' ? req.query.token : '';
            if (!rawToken) {
                res.status(400).send(resetPasswordPage('', 'This reset link is missing its token.'));
                return;
            }
            res.status(200).send(resetPasswordPage(rawToken));
            return;
        }

        const rawToken = typeof req.body?.token === 'string'
            ? req.body.token
            : (typeof req.query.token === 'string' ? req.query.token : '');
        const newPassword = typeof req.body?.password === 'string' ? req.body.password : '';
        const isBrowserForm = Boolean(req.is('application/x-www-form-urlencoded'));

        try {
            if (!rawToken) {
                throw new Error('This reset link is invalid or has expired.');
            }

            const passwordCheck = validatePasswordStrength(newPassword);
            if (!passwordCheck.isValid) {
                throw new Error(passwordCheck.errors.join(' '));
            }

            const tokenHash = createHash('sha256').update(rawToken).digest('hex');
            const salt = await bcrypt.genSalt(BCRYPT_SALT_ROUNDS);
            const passwordHash = await bcrypt.hash(newPassword, salt);

            const user = await UserRepository.resetPassword(tokenHash, passwordHash);
            if (!user) {
                throw new Error('This reset link is invalid or has expired.');
            }

            if (isBrowserForm) {
                res.status(200).send(verificationPage(
                    'Password updated',
                    'Your password has been changed successfully.',
                    true,
                ));
                return;
            }
            res.status(200).json({ message: 'Password updated successfully.' });
        } catch (error) {
            const message = error instanceof Error ? error.message : 'Unable to reset password.';
            if (isBrowserForm) {
                res.status(400).send(resetPasswordPage(rawToken, message));
                return;
            }
            res.status(400).json({ error: message });
        }
    }

    // Lists this account's active sessions/devices (e.g. mobile + web signed in
    // at once), for a "manage active sessions" settings screen.
    static async listSessions(req: Request, res: Response): Promise<void> {
        try {
            const sessions = await SessionRepository.listActive(req.user!.userId);
            res.status(200).json({
                sessions: sessions.map((session) => ({
                    id: session.id,
                    platform: session.platform,
                    deviceName: session.device_name,
                    createdAt: session.created_at,
                    lastSeenAt: session.last_seen_at,
                    isCurrent: session.id === req.user!.sessionId,
                })),
            });
        } catch (error) {
            logger.error('Failed to list sessions:', error);
            res.status(500).json({ error: 'Unable to load active sessions right now.' });
        }
    }

    // Selective logout: signs out one specific device without affecting the
    // account's other active sessions.
    static async revokeSession(req: Request, res: Response): Promise<void> {
        try {
            const { sessionId } = req.params;
            const revoked = await SessionRepository.revoke(sessionId, req.user!.userId);
            if (!revoked) {
                res.status(404).json({ error: 'Session not found or already signed out.' });
                return;
            }

            const io = getIO();
            if (io) {
                io.in(`session:${sessionId}`).emit('force_logout', {
                    message: 'You were logged out of this device.',
                });
                io.in(`session:${sessionId}`).disconnectSockets(true);
            }

            res.status(200).json({ message: 'That device has been logged out.' });
        } catch (error) {
            logger.error('Failed to revoke session:', error);
            res.status(500).json({ error: 'Unable to log out that device right now.' });
        }
    }

    // Clean logout of the calling device's own session (as opposed to the
    // client just discarding its token locally), so it stops appearing as
    // "active" to the account's other devices.
    static async logout(req: Request, res: Response): Promise<void> {
        try {
            if (req.user?.sessionId) {
                await SessionRepository.revoke(req.user.sessionId, req.user.userId);
            }
            res.status(200).json({ message: 'Logged out.' });
        } catch (error) {
            logger.error('Failed to log out:', error);
            res.status(500).json({ error: 'Unable to log out right now.' });
        }
    }
}