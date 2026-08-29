// Shared between REST auth middleware and the Socket.IO handshake so both
// enforce the same per-device session check: a JWT is only valid as long as
// the specific session row it was issued for hasn't been revoked (by a
// selective logout of that device, or a clean logout from that device).
// Multiple sessions (e.g. mobile + web) can be active for the same account
// at once — this is not a single-session check.
import { SessionRepository } from '../repositories/session.repository';
import type { AuthenticatedUser } from '../middleware/auth.middleware';

export async function hasValidSession(decoded: AuthenticatedUser | string | undefined): Promise<boolean> {
    if (!decoded || typeof decoded === 'string' || typeof decoded.sessionId !== 'string' || typeof decoded.userId !== 'string') {
        return false;
    }
    return SessionRepository.isActive(decoded.sessionId, decoded.userId);
}
