// Single source of truth for Socket.IO event names used by the frontend.
class SocketEvents {
  SocketEvents._();

  // Built-in Socket.IO client lifecycle event.
  static const String connect = 'connect';

  // Emitted by this client to the server.
  static const String joinChat = 'join_chat';
  static const String sendMessage = 'send_message';
  static const String updateMessageStatus = 'update_message_status';
  static const String typing = 'typing';
  static const String editMessage = 'edit_message';
  static const String deleteMessage = 'delete_message';

  // Broadcast by the server to this client.
  static const String receiveMessage = 'receive_message';
  static const String errorFeedback = 'error_feedback';
  static const String userTyping = 'user_typing';
  static const String messageEdited = 'message_edited';
  static const String messageDeleted = 'message_deleted';
  static const String messagesRead = 'messages_read';
  static const String chatRead = 'chat_read';
  static const String messageStatusUpdated = 'message_status_updated';
  static const String friendRemoved = 'friend_removed';
  static const String newInvite = 'new_invite';
  static const String inviteResponded = 'invite_responded';
  static const String profileUpdated = 'profile_updated';
  static const String groupMemberAdded = 'group_member_added';
  static const String groupMemberRemoved = 'group_member_removed';
  static const String groupRenamed = 'group_renamed';
  static const String pollUpdated = 'poll_updated';

  // Emitted by the server right before disconnecting a socket whose account
  // just logged in on a different device (single-active-session enforcement).
  static const String forceLogout = 'force_logout';
}
