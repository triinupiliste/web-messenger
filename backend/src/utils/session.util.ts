// Shared by REST middleware and the Socket.IO handshake: a JWT is valid only
// while its specific session row hasn't been revoked. Multiple sessions (e.g.
// mobile + web) can be active for the same account at once.
import { SessionRepository } from '../repositories/session.repository';
import type { AuthenticatedUser } from '../middleware/auth.middleware';

export async function hasValidSession(decoded: AuthenticatedUser | string | undefined): Promise<boolean> {
    if (!decoded || typeof decoded === 'string' || typeof decoded.sessionId !== 'string' || typeof decoded.userId !== 'string') {
        return false;
    }
    return SessionRepository.isActive(decoded.sessionId, decoded.userId);
}
