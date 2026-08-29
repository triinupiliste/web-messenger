import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import { JWT_SECRET } from '../config/env';
import { hasValidSession } from '../utils/session.util';

// Decoded JWT payload attached to the request by verifyToken/verifyMediaToken.
export interface AuthenticatedUser {
    userId: string;
    email: string;
    sessionId?: string;
}

// Augments Express's own Request type so any handler behind verifyToken/
// verifyMediaToken can read req.user without an `as any` cast. Optional
// because it's only actually present once those middlewares run.
declare global {
    namespace Express {
        interface Request {
            user?: AuthenticatedUser;
        }
    }
}

// Recognized by the Flutter app's AuthProvider/ApiService to force a local
// logout instead of showing a generic "session expired" error.
const SESSION_INVALIDATED_RESPONSE = {
    error: 'You have been logged out because your account was signed in on another device.',
    code: 'SESSION_INVALIDATED',
};

export function verifyToken(req: Request, res: Response, next: NextFunction): void {
    const authHeader = req.headers['authorization'];
    const token = authHeader && authHeader.split(' ')[1]; // Expecting "Bearer <TOKEN>"

    if (!token) {
        res.status(401).json({ error: 'Access token missing or malformed.' });
        return;
    }

    jwt.verify(token, JWT_SECRET, (err, decoded) => {
        if (err) {
            res.status(403).json({ error: 'Token is invalid or expired.' });
            return;
        }
        const user = decoded as AuthenticatedUser;
        hasValidSession(user).then((valid) => {
            if (!valid) {
                res.status(401).json(SESSION_INVALIDATED_RESPONSE);
                return;
            }
            req.user = user;
            next();
        }).catch(() => {
            res.status(500).json({ error: 'Internal server error during authentication.' });
        });
    });
}

// Same as verifyToken, but also accepts the JWT via ?token= — native media
// widgets (Image, VideoPlayerController, etc.) load by URL and can't set headers.
export function verifyMediaToken(req: Request, res: Response, next: NextFunction): void {
    const authHeader = req.headers['authorization'];
    const headerToken = authHeader && authHeader.split(' ')[1];
    const queryToken = typeof req.query.token === 'string' ? req.query.token : undefined;
    const token = headerToken || queryToken;

    if (!token) {
        res.status(401).json({ error: 'Access token missing or malformed.' });
        return;
    }

    jwt.verify(token, JWT_SECRET, (err, decoded) => {
        if (err) {
            res.status(403).json({ error: 'Token is invalid or expired.' });
            return;
        }
        const user = decoded as AuthenticatedUser;
        hasValidSession(user).then((valid) => {
            if (!valid) {
                res.status(401).json(SESSION_INVALIDATED_RESPONSE);
                return;
            }
            req.user = user;
            next();
        }).catch(() => {
            res.status(500).json({ error: 'Internal server error during authentication.' });
        });
    });
}