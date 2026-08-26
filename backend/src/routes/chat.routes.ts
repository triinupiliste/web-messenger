import { Router } from 'express';
import { ChatController } from '../controllers/chat.controller';
import { verifyToken } from '../middleware/auth.middleware';

const router = Router();

router.get('/', verifyToken, ChatController.getChatList);
router.post('/group', verifyToken, ChatController.createGroup);
router.patch('/:chatId/archive', verifyToken, ChatController.toggleArchiveChat);
router.patch('/:chatId/mute', verifyToken, ChatController.toggleMuteChat);
router.patch('/:chatId/delete', verifyToken, ChatController.toggleDeleteChat);
router.patch('/:chatId/remove-friend', verifyToken, ChatController.removeFriend);
router.patch('/:chatId/name', verifyToken, ChatController.renameGroup);
router.get('/:chatId/members', verifyToken, ChatController.getGroupMembers);
router.delete('/:chatId/members/:userId', verifyToken, ChatController.removeMember);
router.get('/:chatId/messages', verifyToken, ChatController.getChatMessages);
router.get('/:chatId/search', verifyToken, ChatController.searchMessages);
router.patch('/:chatId/read', verifyToken, ChatController.markMessagesRead);

export default router;