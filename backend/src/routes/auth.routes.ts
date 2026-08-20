import { Router } from 'express';
import { AuthController } from '../controllers/auth.controller';
import { verifyToken } from '../middleware/auth.middleware';

const router = Router();

router.post('/register', AuthController.register);
router.post('/login', AuthController.login);
router.get('/verify-email', AuthController.verifyEmail);
router.post('/resend-verification', AuthController.resendVerificationEmail);
router.post('/request-password-reset', AuthController.requestPasswordReset);
router.get('/reset-password', AuthController.resetPassword);
router.post('/reset-password', AuthController.resetPassword);
router.post('/logout', verifyToken, AuthController.logout);
router.get('/sessions', verifyToken, AuthController.listSessions);
router.delete('/sessions/:sessionId', verifyToken, AuthController.revokeSession);

export default router;