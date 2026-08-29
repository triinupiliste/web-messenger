import rateLimit from 'express-rate-limit';
import { Request } from 'express';

// Rate-limits by authenticated user, not IP — these limiters are only mounted
// after verifyToken, and the real abuse vector here is one account spamming
// requests, not shared-IP traffic.
function userKeyGenerator(req: Request): string {
    return req.user!.userId;
}

export const pollVoteLimiter = rateLimit({
    windowMs: 60 * 1000,
    limit: 30,
    standardHeaders: true,
    legacyHeaders: false,
    keyGenerator: userKeyGenerator,
    message: { error: 'Too many votes. Please slow down.' },
});

export const inviteLimiter = rateLimit({
    windowMs: 60 * 60 * 1000,
    limit: 20,
    standardHeaders: true,
    legacyHeaders: false,
    keyGenerator: userKeyGenerator,
    message: { error: 'Too many invites sent. Please try again later.' },
});
