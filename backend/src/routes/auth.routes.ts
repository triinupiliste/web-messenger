import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { AuthController } from '../controllers/auth.controller';
import { verifyToken } from '../middleware/auth.middleware';

const router = Router();

// Throttles the endpoints attackers would use for brute-forcing passwords,
// spraying credentials, or enumerating registered emails/usernames.
const authLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: 10,
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: 'Too many attempts. Please try again later.' },
});

router.post('/register', authLimiter, AuthController.register);
router.post('/login', authLimiter, AuthController.login);
router.get('/verify-email', AuthController.verifyEmail);
router.post('/resend-verification', authLimiter, AuthController.resendVerificationEmail);
router.post('/request-password-reset', authLimiter, AuthController.requestPasswordReset);
router.get('/reset-password', AuthController.resetPassword);
router.post('/reset-password', authLimiter, AuthController.resetPassword);
router.post('/logout', verifyToken, AuthController.logout);
router.get('/sessions', verifyToken, AuthController.listSessions);
router.delete('/sessions/:sessionId', verifyToken, AuthController.revokeSession);

export default router;