import { Router } from 'express';
import { PollController } from '../controllers/poll.controller';
import { verifyToken } from '../middleware/auth.middleware';
import { pollVoteLimiter } from '../middleware/rate-limit.middleware';

const router = Router();

router.post('/', verifyToken, PollController.createPoll);
router.get('/:pollId', verifyToken, PollController.getPoll);
router.post('/:pollId/vote', verifyToken, pollVoteLimiter, PollController.vote);
router.patch('/:pollId/close', verifyToken, PollController.closePoll);

export default router;
