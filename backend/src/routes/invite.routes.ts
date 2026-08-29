import { Router } from 'express';
import { InviteController } from '../controllers/invite.controller';
import { verifyToken } from '../middleware/auth.middleware';
import { inviteLimiter } from '../middleware/rate-limit.middleware';

const router = Router();

router.post('/', verifyToken, inviteLimiter, InviteController.sendInvite);
router.get('/', verifyToken, InviteController.getPendingInvites);
router.post('/respond', verifyToken, InviteController.respondToInvite);

export default router;