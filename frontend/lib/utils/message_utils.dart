// Shared by message_bubble.dart and chat_room_screen.dart to render the
// same reply-preview text for a quoted message.
String replyPreviewText(Map<String, dynamic> reply) {
  if (reply['is_deleted'] == true) return 'This message was deleted';
  final content = (reply['content'] ?? '').toString();
  if (content.isNotEmpty) return content;
  switch (reply['media_type']) {
    case 'image':
      return 'Photo';
    case 'video':
      return 'Video';
    case 'audio':
      return 'Voice message';
    case 'poll':
      return '📊 Poll';
    default:
      return '';
  }
}
