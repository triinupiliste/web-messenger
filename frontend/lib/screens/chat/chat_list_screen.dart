import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
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
  // When set (wide-screen split-pane layout only), tapping a chat calls
  // onChatSelected to update the detail pane(s) in place instead of pushing a
  // full-screen ChatRoomScreen route; openChatIds highlights every row that
  // currently has its own open pane (on web, more than one can be open at once).
  final bool splitPaneMode;
  final Set<String> openChatIds;
  final void Function(String chatId, String contactId, String contactName, bool isGroup)? onChatSelected;

  const ChatListScreen({
    super.key,
    this.splitPaneMode = false,
    this.openChatIds = const {},
    this.onChatSelected,
  });

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  bool _showArchived = false;
  String? _currentUserId;
  // Web-only: chat rows currently hovered, to reveal their menu button (see
  // _buildChatMenuButton). Mobile uses swipe gestures instead, so this stays empty there.
  final Set<String> _hoveredChatIds = {};

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

  // Chat-list-style relative timestamp for the last message, mirroring the
  // common convention: just the time for today, "Yesterday" for yesterday,
  // the shortened weekday within the last week, the date without a year for
  // anything older this year, and the date with a year for previous years.
  String _formatLastMessageTime(DateTime? time) {
    if (time == null) return '';
    final local = time.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDay = DateTime(local.year, local.month, local.day);
    final daysAgo = today.difference(messageDay).inDays;

    if (daysAgo <= 0) {
      return DateFormat('HH:mm').format(local);
    } else if (daysAgo == 1) {
      return 'Yesterday';
    } else if (daysAgo < 7) {
      return DateFormat('EEE').format(local);
    } else if (local.year == now.year) {
      return DateFormat('d MMM').format(local);
    } else {
      return DateFormat('d MMM yyyy').format(local);
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

  // Shared by both the mobile swipe-to-archive gesture and the web menu button.
  void _archiveOrUnarchiveChat(ChatProvider chatProvider, String chatId, bool isArchived) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
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
  }

  // Shared by both the mobile swipe-to-delete gesture and the web menu button.
  void _deleteChatWithUndo(ChatProvider chatProvider, String chatId) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
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
  }

  // Web has no swipe gestures, so a small hover-revealed button offers the
  // same archive/delete actions instead (mirrors message_bubble.dart's web
  // hover-menu pattern).
  Widget _buildChatMenuButton(ChatProvider chatProvider, String chatId, bool isArchived) {
    return Material(
      color: AppColors.surface,
      shape: const CircleBorder(),
      elevation: 2,
      child: PopupMenuButton<String>(
        icon: Icon(Icons.more_vert, size: 18, color: AppColors.textSecondary),
        padding: EdgeInsets.zero,
        tooltip: 'Chat options',
        onSelected: (value) {
          if (value == 'archive') {
            _archiveOrUnarchiveChat(chatProvider, chatId, isArchived);
          } else if (value == 'delete') {
            _deleteChatWithUndo(chatProvider, chatId);
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'archive',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(isArchived ? Icons.unarchive : Icons.archive, size: 18, color: AppColors.textPrimary),
                const SizedBox(width: 8),
                Text(isArchived ? 'Unarchive' : 'Archive'),
              ],
            ),
          ),
          const PopupMenuItem(
            value: 'delete',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.delete, size: 18, color: Colors.red),
                SizedBox(width: 8),
                Text('Delete', style: TextStyle(color: Colors.red)),
              ],
            ),
          ),
        ],
      ),
    );
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

              final content = Container(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: (widget.splitPaneMode && widget.openChatIds.contains(chatId))
                      ? AppColors.primary.withValues(alpha: 0.1)
                      : AppColors.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: (widget.splitPaneMode && widget.openChatIds.contains(chatId))
                        ? AppColors.primary
                        : AppColors.cardBorder,
                  ),
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
                  trailing: SizedBox(
                    height: 42,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
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
                          )
                        else
                          const SizedBox.shrink(),
                        Text(
                          _formatLastMessageTime(chat.lastMessageTime),
                          style: TextStyle(
                            fontSize: 12,
                            color: hasUnread ? AppColors.primary : AppColors.textSecondary,
                            fontWeight: hasUnread ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                  onTap: () async {
                    final chatProv = context.read<ChatProvider>();

                    if (widget.splitPaneMode) {
                      widget.onChatSelected?.call(chatId, chat.contactId, contactName, chat.isGroup);
                      return;
                    }

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
              );

              // Web has no swipe gestures, so archive/delete are offered via a
              // hover-revealed menu button in the row's top-right corner instead
              // (mirroring the message bubble's web hover-menu pattern). Mobile
              // keeps the original swipe-to-archive/swipe-to-delete behavior.
              if (kIsWeb) {
                final isHovered = _hoveredChatIds.contains(chatId);
                return MouseRegion(
                  onEnter: (_) => setState(() => _hoveredChatIds.add(chatId)),
                  onExit: (_) => setState(() => _hoveredChatIds.remove(chatId)),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      content,
                      if (isHovered)
                        Positioned(
                          top: 0,
                          bottom: 0,
                          right: 18,
                          child: Center(child: _buildChatMenuButton(chatProvider, chatId, isArchived)),
                        ),
                    ],
                  ),
                );
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
                  if (direction == DismissDirection.startToEnd) {
                    _archiveOrUnarchiveChat(chatProvider, chatId, isArchived);
                  } else {
                    _deleteChatWithUndo(chatProvider, chatId);
                  }
                  return true;
                },
                child: content,
              );
            },
          );
        },
      ),
    );
  }
}