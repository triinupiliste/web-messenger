import rateLimit from 'express-rate-limit';
import { Request } from 'express';

// Rate-limits by authenticated user rather than by IP. These limiters are only
// ever mounted after verifyToken, so req.user is always populated here — IP-based
// limiting would be the wrong dimension for them anyway, since multiple legitimate
// users can share an IP (NAT/mobile carriers/shared wifi), while the actual abuse
// vector is a single account spamming requests, not anonymous credential stuffing.
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
