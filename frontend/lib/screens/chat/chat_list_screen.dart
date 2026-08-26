import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/chat_provider.dart';
import '../../services/api_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/json_utils.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/common/empty_state.dart';
import '../../widgets/common/user_avatar.dart';
import '../search/search_screen.dart';
import 'chat_room_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  bool _showArchived = false;
  String? _currentUserId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<ChatProvider>(context, listen: false).fetchChats();
    });
    _loadCurrentUserId();
  }

  Future<void> _loadCurrentUserId() async {
    try {
      final profile = await ApiService.getProfile();
      if (!mounted) return;
      setState(() {
        _currentUserId = extractUserId(profile);
      });
    } catch (_) {
      // Ignore; falls back to showing messages without the 'You:' prefix.
    }
  }

  String? _mediaPreviewLabel(String? mediaType) {
    switch (mediaType) {
      case 'image':
        return 'Sent a photo';
      case 'video':
        return 'Sent a video';
      case 'audio':
        return 'Sent a voice message';
      case 'poll':
        return '📊 Created a poll';
      default:
        return null;
    }
  }

  Future<void> _createGroup() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Group'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 100,
          decoration: const InputDecoration(hintText: 'Group name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (name == null || name.isEmpty || !mounted) return;

    try {
      final chatId = await context.read<ChatProvider>().createGroup(name);
      if (!mounted) return;
      // Immediately prompt to add members to the group just created.
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => SearchScreen(groupChatId: chatId)),
      );
      if (!mounted) return;
      context.read<ChatProvider>().fetchChats();
    } catch (e) {
      if (!mounted) return;
      SnackBarHelper.show(context, 'Failed to create group: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_showArchived ? 'Archived Messages' : 'Messages'),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_add_outlined),
            tooltip: 'New Group',
            onPressed: _createGroup,
          ),
          IconButton(
            icon: Icon(_showArchived ? Icons.archive : Icons.archive_outlined),
            tooltip: 'Toggle Archived Chats',
            onPressed: () {
              setState(() {
                _showArchived = !_showArchived;
              });
            },
          ),
        ],
      ),
      body: Consumer<ChatProvider>(
        builder: (context, chatProvider, child) {
          if (chatProvider.isLoading) {
            return Center(child: CircularProgressIndicator(color: AppColors.primary));
          }

          final filteredChats = chatProvider.chats.where((chat) {
            return _showArchived ? chat.isArchived : !chat.isArchived;
          }).toList();

          if (filteredChats.isEmpty) {
            return EmptyState(
              icon: _showArchived ? Icons.archive_outlined : Icons.chat_bubble_outline_rounded,
              title: _showArchived ? 'No archived chats' : 'No conversations yet',
              subtitle: _showArchived ? null : 'Search for contacts to start chatting!',
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: filteredChats.length,
            itemBuilder: (context, index) {
              final chat = filteredChats[index];
              final chatId = chat.chatId;
              final contactName = chat.contactName;
              final isArchived = chat.isArchived;

              final isFromMe = _currentUserId != null && chat.lastMessageSenderId == _currentUserId;
              // Only bold the preview for unread messages the *other* person sent.
              final hasUnread = chat.unreadCount > 0 && !isFromMe;

              final hasTextContent = chat.lastMessage != null && chat.lastMessage!.isNotEmpty;
              final mediaLabel = _mediaPreviewLabel(chat.lastMessageType);

              final String previewText;
              if (!hasTextContent && mediaLabel == null) {
                previewText = 'Start a conversation';
              } else {
                final body = hasTextContent ? chat.lastMessage! : mediaLabel!;
                previewText = isFromMe ? 'You: $body' : body;
              }

              return Dismissible(
                key: Key(chatId),
                background: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppColors.warning,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Icon(isArchived ? Icons.unarchive : Icons.archive, color: AppColors.onPrimary),
                ),
                secondaryBackground: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppColors.error,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Icon(Icons.delete, color: AppColors.onPrimary),
                ),
                confirmDismiss: (direction) async {
                  final messenger = ScaffoldMessenger.of(context);
                  messenger.clearSnackBars();

                  if (direction == DismissDirection.startToEnd) {
                    chatProvider.toggleArchiveChat(chatId);
                    final controller = SnackBarHelper.showWithMessenger(
                      messenger,
                      isArchived ? 'Chat unarchived' : 'Chat archived',
                      duration: const Duration(seconds: 5),
                      action: SnackBarAction(
                        label: 'Undo',
                        onPressed: () => chatProvider.toggleArchiveChat(chatId),
                      ),
                    );
                    Future.delayed(const Duration(seconds: 5), controller.close);
                    return true;
                  }

                  chatProvider.deleteChat(chatId);
                  final controller = SnackBarHelper.showWithMessenger(
                    messenger,
                    'Chat deleted',
                    duration: const Duration(seconds: 5),
                    action: SnackBarAction(
                      label: 'Undo',
                      onPressed: () => chatProvider.undoDeleteChat(),
                    ),
                  );
                  Future.delayed(const Duration(seconds: 5), controller.close);
                  return true;
                },
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.cardBorder),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.softShadow,
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: ListTile(
                    leading: chat.isGroup
                        ? CircleAvatar(
                            backgroundColor: AppColors.primary.withValues(alpha: 0.15),
                            child: Icon(Icons.groups_rounded, color: AppColors.primary),
                          )
                        : UserAvatar(
                            avatarUrl: chat.contactAvatar,
                            displayName: contactName,
                          ),
                    title: Text(contactName, style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                    subtitle: Text(
                      previewText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: hasUnread ? AppColors.textPrimary : AppColors.textSecondary,
                        fontWeight: hasUnread ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (hasUnread)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  AppColors.primary,
                                  AppColors.darken(AppColors.primary),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.primary.withValues(alpha: 0.3),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            constraints: const BoxConstraints(minWidth: 22),
                            child: Text(
                              chat.unreadCount > 99 ? '99+' : '${chat.unreadCount}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: AppColors.onPrimary, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ),
                        const SizedBox(width: 4),
                        Icon(Icons.chevron_right, size: 18, color: AppColors.textSecondary),
                      ],
                    ),
                    onTap: () async {
                      final chatProv = context.read<ChatProvider>();

                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ChatRoomScreen(
                            chatId: chatId,
                            contactId: chat.contactId,
                            contactName: contactName,
                            isGroup: chat.isGroup,
                          ),
                        ),
                      );

                      if (!mounted) return;
                      chatProv.fetchChats();
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}