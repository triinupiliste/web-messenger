class ChatModel {
  final String chatId;
  final bool isGroup;
  final String contactId;
  final String contactName;
  final String? contactAvatar;
  final int? memberCount;
  final String? lastMessage;
  final String? lastMessageType;
  final DateTime? lastMessageTime;
  final String? lastMessageSenderId;
  final int unreadCount;
  bool isArchived;
  bool isMuted;

  ChatModel({
    required this.chatId,
    this.isGroup = false,
    this.contactId = '',
    required this.contactName,
    this.contactAvatar,
    this.memberCount,
    this.lastMessage,
    this.lastMessageType,
    this.lastMessageTime,
    this.lastMessageSenderId,
    this.unreadCount = 0,
    this.isArchived = false,
    this.isMuted = false,
  });

  factory ChatModel.fromJson(Map<String, dynamic> json) {
    return ChatModel(
      chatId: json['chat_id'] ?? '',
      isGroup: json['is_group'] ?? false,
      contactId: (json['contact_id'] ?? '').toString(),
      contactName: json['contact_username'] ?? 'User',
      contactAvatar: json['contact_avatar'],
      memberCount: json['member_count'] is int
          ? json['member_count']
          : int.tryParse(json['member_count']?.toString() ?? ''),
      lastMessage: json['last_message_content'],
      lastMessageType: json['last_message_type'],
      lastMessageTime: json['last_message_time'] != null
          ? DateTime.parse(json['last_message_time'])
          : null,
      lastMessageSenderId: json['last_message_sender_id'],
      unreadCount: json['unread_count'] is int
          ? json['unread_count']
          : int.tryParse(json['unread_count']?.toString() ?? '') ?? 0,
      isArchived: json['is_archived'] ?? false,
      isMuted: json['is_muted'] ?? false,
    );
  }
}