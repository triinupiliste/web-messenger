import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../../constants/socket_events.dart';
import '../../providers/chat_provider.dart';
import '../../providers/message_provider.dart';
import '../../services/api_service.dart';
import '../../services/socket_service.dart';
import '../../services/audio_service.dart';
import '../../services/notification_service.dart';
import '../../services/push_notification_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/message_utils.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/chat/message_bubble.dart';
import '../../widgets/chat/typing_indicator_bubble.dart';
import '../../widgets/common/empty_state.dart';
import '../../widgets/common/user_avatar.dart';
import '../home/home_screen.dart';
import 'group_info_screen.dart';

// Thin wrapper that scopes a fresh MessageProvider to this specific chat room,
// created and disposed with the screen rather than registered globally.
class ChatRoomScreen extends StatelessWidget {
  final String chatId;
  final String contactId;
  final String contactName;
  final bool isGroup;

  const ChatRoomScreen({
    super.key,
    required this.chatId,
    this.contactId = '',
    required this.contactName,
    this.isGroup = false,
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => MessageProvider(chatId)..init(),
      child: _ChatRoomView(chatId: chatId, contactId: contactId, contactName: contactName, isGroup: isGroup),
    );
  }
}

class _ChatRoomView extends StatefulWidget {
  final String chatId;
  final String contactId;
  final String contactName;
  final bool isGroup;

  const _ChatRoomView({
    required this.chatId,
    required this.contactId,
    required this.contactName,
    required this.isGroup,
  });

  @override
  State<_ChatRoomView> createState() => _ChatRoomViewState();
}

class _ChatRoomViewState extends State<_ChatRoomView> {
  final TextEditingController _messageController = TextEditingController();
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener = ItemPositionsListener.create();
  final AudioService _audioService = AudioService();

  late final MessageProvider _messageProvider;
  int _lastMessageCount = 0;
  bool _lastLoadingHistory = true;

  bool _isRecording = false;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;
  bool _isUploadingMedia = false;
  bool _showJumpToLatestButton = false;
  Map<String, dynamic>? _replyingTo;

  // Group chats only: userId -> username, used to label messages/replies with
  // the actual sender's name instead of a single hardcoded "contact".
  Map<String, String> _memberNames = {};

  // Stored so dispose() can unregister exactly these callbacks rather than
  // leaking listeners on the shared socket singleton.
  late final void Function(dynamic) _onErrorFeedback;
  late final void Function(dynamic) _onFriendRemoved;
  late final void Function(dynamic) _onGroupMemberRemoved;
  late final void Function(dynamic) _onGroupRenamed;

  // Overrides widget.contactName once a 'group_renamed' event arrives for this chat.
  String? _liveGroupName;

  @override
  void initState() {
    super.initState();

    _messageProvider = context.read<MessageProvider>();
    _lastMessageCount = _messageProvider.messages.length;
    _lastLoadingHistory = _messageProvider.isLoadingHistory;
    _messageProvider.addListener(_onMessagesChanged);

    // Mark this chat as the one currently on screen, so a foreground push
    // notification for it can be suppressed (already visible live here).
    ActiveChatTracker.setActiveChat(widget.chatId);

    // Whether opened via a notification tap or directly through the app, its
    // messages are read the moment this screen is on screen — clear any
    // pending tray notification for it instead of leaving it lingering.
    PushNotificationService.cancelForChat(widget.chatId);

    // This is a UI-only concern (showing a SnackBar), so it stays registered
    // directly by the screen rather than living in MessageProvider.
    _onErrorFeedback = (data) {
      if (!mounted) return;
      SnackBarHelper.show(context, data['message']?.toString() ?? 'Something went wrong.');
    };
    SocketService.on(SocketEvents.errorFeedback, _onErrorFeedback);

    // If the other person removes us as a friend while we're in this chat, bounce
    // back to the chat list instead of leaving a dead conversation on screen.
    _onFriendRemoved = (data) {
      if (!mounted) return;
      final removedChatId = data['chatId']?.toString();
      if (removedChatId != widget.chatId) return;
      // Capture the messenger before popping — once this route is gone,
      // `context` here is no longer safely usable to look one up.
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).popUntil((route) => route.isFirst);
      HomeScreen.homeKey.currentState?.switchToChatsTab();
      SnackBarHelper.showWithMessenger(messenger, '${widget.contactName} removed you as a friend.');
    };
    SocketService.on(SocketEvents.friendRemoved, _onFriendRemoved);

    // If we're removed from (or leave) this group from another device, or the
    // owner removes us, bounce back to the chat list instead of leaving a dead
    // conversation on screen.
    _onGroupMemberRemoved = (data) {
      if (!mounted || !widget.isGroup) return;
      if (data['chatId']?.toString() != widget.chatId) return;
      final userId = _messageProvider.currentUserId;
      if (userId == null || data['userId']?.toString() != userId) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).popUntil((route) => route.isFirst);
      HomeScreen.homeKey.currentState?.switchToChatsTab();
      SnackBarHelper.showWithMessenger(messenger, 'You are no longer a member of this group.');
    };
    SocketService.on(SocketEvents.groupMemberRemoved, _onGroupMemberRemoved);

    // The group was renamed while this screen is open; update the AppBar title live.
    _onGroupRenamed = (data) {
      if (!mounted || !widget.isGroup) return;
      if (data['chatId']?.toString() != widget.chatId) return;
      setState(() => _liveGroupName = data['name']?.toString());
    };
    SocketService.on(SocketEvents.groupRenamed, _onGroupRenamed);

    // Track which messages are actually on screen so we can show a "more
    // messages" pill whenever there's an unread message hidden below the fold.
    _itemPositionsListener.itemPositions.addListener(_handleItemPositionsChanged);

    if (widget.isGroup) {
      _loadGroupMembers();
    }
  }

  Future<void> _loadGroupMembers() async {
    try {
      final members = await ApiService.getGroupMembers(widget.chatId);
      if (!mounted) return;
      setState(() {
        _memberNames = {
          for (final m in members)
            (m['user_id'] ?? '').toString(): (m['username'] ?? 'User').toString(),
        };
      });
    } catch (e) {
      // Non-fatal: sender labels just fall back to "Member" until this succeeds.
    }
  }

  // Reacts to MessageProvider changes: jumps to the first unread message once
  // history loads, auto-scrolls on new messages, and recomputes the "jump to latest" pill.
  void _onMessagesChanged() {
    final isLoadingHistory = _messageProvider.isLoadingHistory;
    if (_lastLoadingHistory && !isLoadingHistory) {
      _jumpToInitialPosition();
    }
    _lastLoadingHistory = isLoadingHistory;

    final messageCount = _messageProvider.messages.length;
    if (messageCount > _lastMessageCount) {
      _scrollToBottom();
    }
    _lastMessageCount = messageCount;

    _handleItemPositionsChanged();
  }

  void _handleItemPositionsChanged() {
    final messages = _messageProvider.messages;
    if (messages.isEmpty) return;
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;

    final lastVisibleIndex = positions.map((p) => p.index).reduce((a, b) => a > b ? a : b);

    // Only show the pill when an unread message from the other participant is
    // still hidden below the viewport, not just whenever scrolled away from the bottom.
    final hasUnreadBelow = messages.asMap().entries.any((entry) =>
        entry.key > lastVisibleIndex &&
        entry.value['sender_id'] != _messageProvider.currentUserId &&
        entry.value['status'] != 'read' &&
        entry.value['is_deleted'] != true);

    if (hasUnreadBelow != _showJumpToLatestButton && mounted) {
      setState(() => _showJumpToLatestButton = hasUnreadBelow);
    }
  }

  String _formatTimestamp(dynamic createdAt) {
    if (createdAt == null) return '';
    final parsed = DateTime.tryParse(createdAt.toString());
    if (parsed == null) return '';

    final local = parsed.toLocal();
    final time = DateFormat('HH:mm').format(local);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDay = DateTime(local.year, local.month, local.day);
    final daysAgo = today.difference(messageDay).inDays;

    if (daysAgo <= 0) {
      return time;
    } else if (daysAgo == 1) {
      return 'Yesterday $time';
    } else if (daysAgo < 7) {
      return '${DateFormat('EEE').format(local)} $time';
    } else {
      // Year is only included when the message isn't from the current year.
      final datePattern = local.year == now.year ? 'd MMM' : 'd MMM yyyy';
      return '${DateFormat(datePattern).format(local)} $time';
    }
  }

  // Jumps to the first unread message so the user lands where they left off;
  // if everything is already read, lands on the last message like normal.
  void _jumpToInitialPosition() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final messages = _messageProvider.messages;
      if (!_itemScrollController.isAttached || messages.isEmpty) return;

      final firstUnreadIndex = messages.indexWhere((m) =>
          m['sender_id'] != _messageProvider.currentUserId &&
          m['status'] != 'read' &&
          m['is_deleted'] != true);

      if (firstUnreadIndex == -1) {
        // The sentinel item (index == messages.length) has ~zero height, so aligning
        // its top to the viewport's bottom is equivalent to flushing the last message down.
        _itemScrollController.jumpTo(index: messages.length, alignment: 1.0);
      } else {
        _itemScrollController.jumpTo(index: firstUnreadIndex, alignment: 0.0);
      }
    });
  }

  // Jumps to the latest message when a new one arrives while the chat is open.
  // Uses jumpTo() instead of scrollTo(): scrollTo() animates toward an estimated
  // position for the not-yet-laid-out new item and visibly "snaps back" once the
  // real size is known, whereas jumpTo() corrects instantly. Targets the sentinel
  // item (index == messages.length) since aligning the real last message's top
  // edge to the viewport bottom would push most of the bubble off-screen.
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final messages = _messageProvider.messages;
      if (!_itemScrollController.isAttached || messages.isEmpty) return;
      _itemScrollController.jumpTo(index: messages.length, alignment: 1.0);
    });
  }

  void _handleTyping(String text) {
    _messageProvider.handleTyping();
  }

  // Sets a message as the target of the next send, shown as a preview above
  // the input bar (and rendered as a quoted excerpt on the sent message).
  void _startReply(Map<String, dynamic> msg) {
    if ((msg['id'] ?? '').toString().isEmpty) return; // don't reply to a still-sending/failed message
    setState(() => _replyingTo = msg);
  }

  void _cancelReply() {
    setState(() => _replyingTo = null);
  }

  String _replySenderLabel(Map<String, dynamic> replyTo) {
    final senderId = replyTo['sender_id']?.toString();
    if (senderId == _messageProvider.currentUserId) return 'You';
    if (widget.isGroup) return _memberNames[senderId] ?? 'Member';
    return widget.contactName;
  }

  void _sendMessage({String? mediaUrl, String mediaType = 'text'}) {
    final content = _messageController.text.trim();
    if (content.isEmpty && mediaUrl == null) return;

    _messageProvider.sendMessage(
      content,
      mediaUrl: mediaUrl,
      mediaType: mediaType,
      replyingTo: _replyingTo,
    );

    setState(() => _replyingTo = null);
    _messageController.clear();
  }

  void _retryMessage(String tempId) {
    _messageProvider.retryMessage(tempId);
  }

  Future<void> _editMessage(String messageId, String currentContent) async {
    final controller = TextEditingController(text: currentContent);
    final newContent = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          decoration: const InputDecoration(hintText: 'Message'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    // Without this, focus bounces back to the message input and reopens the
    // keyboard once the dialog closes.
    FocusManager.instance.primaryFocus?.unfocus();

    if (newContent == null || newContent.isEmpty || newContent == currentContent) return;

    _messageProvider.editMessage(messageId, newContent);
  }

  Future<void> _confirmDeleteMessage(String messageId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete message'),
        content: const Text('This message will be deleted for everyone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    // Same as _editMessage: prevent focus bouncing back and reopening the keyboard.
    FocusManager.instance.primaryFocus?.unfocus();

    if (confirmed != true) return;

    _messageProvider.deleteMessage(messageId);
  }

  Future<void> _pickAndSendMedia(ImageSource source) async {
    final picker = ImagePicker();
    XFile? pickedFile;
    String mediaKind;

    if (source == ImageSource.gallery) {
      // Open the full gallery and let the user pick either a photo or a video directly.
      pickedFile = await picker.pickMedia();
      mediaKind = pickedFile != null ? _guessMediaType(pickedFile) : 'image';
    } else {
      final choice = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: Icon(Icons.photo, color: AppColors.primary),
                title: const Text('Photo'),
                onTap: () => Navigator.pop(context, 'image'),
              ),
              ListTile(
                leading: Icon(Icons.videocam, color: AppColors.primary),
                title: const Text('Video'),
                onTap: () => Navigator.pop(context, 'video'),
              ),
            ],
          ),
        ),
      );

      if (choice == null) return;
      mediaKind = choice;

      if (choice == 'image') {
        pickedFile = await picker.pickImage(source: source);
      } else {
        // Actual compression happens server-side via ffmpeg (video_compress plugin
        // proved unreliable); cap recording length as a sanity bound on upload size.
        pickedFile = await picker.pickVideo(
          source: source,
          maxDuration: const Duration(minutes: 1),
        );
      }
    }

    if (pickedFile == null) return;

    try {
      final file = File(pickedFile.path);
      final fileSizeInMB = await file.length() / (1024 * 1024);

      // Videos are compressed server-side after upload (server enforces the real
      // 20MB-after-compression limit); non-video media isn't compressed, so 20MB
      // is enforced directly here.
      if (mediaKind == 'video' ? fileSizeInMB > 150 : fileSizeInMB > 20) {
        if (mounted) {
          final message = mediaKind == 'video'
              ? 'This video is too large to send. Try a shorter clip.'
              : 'Media file size exceeds the 20MB limit.';
          SnackBarHelper.show(context, message);
        }
        return;
      }

      await _uploadAndSendMedia(file, mediaKind);
    } catch (e) {
      if (mounted) {
        SnackBarHelper.show(context, 'Failed to prepare $mediaKind: ${e.toString().replaceFirst('Exception: ', '')}');
      }
    }
  }

  String _guessMediaType(XFile file) {
    const videoExtensions = {'mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v', '3gp'};
    final ext = file.path.split('.').last.toLowerCase();
    return videoExtensions.contains(ext) ? 'video' : 'image';
  }

  Future<void> _uploadAndSendMedia(File file, String mediaType) async {
    setState(() => _isUploadingMedia = true);
    try {
      final url = await ApiService.uploadMedia(file);
      _sendMessage(mediaUrl: url, mediaType: mediaType);
    } catch (e) {
      if (mounted) {
        SnackBarHelper.show(context, 'Failed to send $mediaType: ${e.toString().replaceFirst('Exception: ', '')}');
      }
    } finally {
      if (mounted) setState(() => _isUploadingMedia = false);
    }
  }

  Future<void> _confirmRemoveFriend() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Friend'),
        content: Text(
          'Remove ${widget.contactName} as a friend? This will remove the chat '
          'for both of you. If you add each other again later, your message '
          'history will be there.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await context.read<ChatProvider>().removeFriend(widget.chatId);
      if (!mounted) return;
      // Land back on the Chats tab specifically (now missing this chat),
      // rather than just popping to whichever tab happened to be active
      // when this chat was opened (e.g. Search or Invites).
      Navigator.popUntil(context, (route) => route.isFirst);
      HomeScreen.homeKey.currentState?.switchToChatsTab();
    } catch (e) {
      if (!mounted) return;
      SnackBarHelper.show(context, 'Failed to remove friend: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> _confirmLeaveGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave Group'),
        content: Text('Leave "${widget.contactName}"? You will need a new invite to rejoin.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final userId = _messageProvider.currentUserId;
      if (userId == null) return;
      await ApiService.removeGroupMember(widget.chatId, userId);
      if (!mounted) return;
      Navigator.popUntil(context, (route) => route.isFirst);
      HomeScreen.homeKey.currentState?.switchToChatsTab();
      context.read<ChatProvider>().fetchChats();
    } catch (e) {
      if (!mounted) return;
      SnackBarHelper.show(context, 'Failed to leave group: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> _viewProfile() async {
    if (widget.contactId.isEmpty) return;

    Map<String, dynamic>? profile;
    String? error;
    try {
      profile = await ApiService.getUserProfile(widget.contactId);
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
    }

    if (!mounted) return;

    if (profile == null) {
      SnackBarHelper.show(context, error ?? 'Failed to load profile.');
      return;
    }

    final avatarUrl = profile['avatar_url']?.toString();
    final username = profile['username']?.toString() ?? widget.contactName;
    final email = profile['email']?.toString() ?? '';
    final aboutMe = profile['about_me']?.toString();

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            UserAvatar(
              avatarUrl: avatarUrl,
              displayName: username,
              radius: 40,
            ),
            const SizedBox(height: 16),
            Text(username, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(email, style: TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                (aboutMe == null || aboutMe.isEmpty) ? 'No bio yet.' : aboutMe,
                style: TextStyle(color: AppColors.textPrimary),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleRecording() async {
    if (!_isRecording) {
      await _audioService.startRecording();
      setState(() {
        _isRecording = true;
        _recordingSeconds = 0;
      });
      // Shows the caller how long they've been talking so far — mirrors the
      // playback side's time display, just counting up instead of down.
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _recordingSeconds++);
      });
    } else {
      _recordingTimer?.cancel();
      _recordingTimer = null;
      final path = await _audioService.stopRecording();
      setState(() => _isRecording = false);
      if (path != null) {
        await _uploadAndSendMedia(File(path), 'audio');
      }
    }
  }

  String _formatRecordingDuration(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    if (ActiveChatTracker.isChatActive(widget.chatId)) {
      ActiveChatTracker.setActiveChat(null);
    }
    _recordingTimer?.cancel();
    _messageProvider.removeListener(_onMessagesChanged);
    SocketService.off(SocketEvents.errorFeedback, _onErrorFeedback);
    SocketService.off(SocketEvents.friendRemoved, _onFriendRemoved);
    SocketService.off(SocketEvents.groupMemberRemoved, _onGroupMemberRemoved);
    SocketService.off(SocketEvents.groupRenamed, _onGroupRenamed);
    _itemPositionsListener.itemPositions.removeListener(_handleItemPositionsChanged);
    _messageController.dispose();
    _audioService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messageProvider = context.watch<MessageProvider>();
    final messages = messageProvider.messages;
    final isLoadingHistory = messageProvider.isLoadingHistory;
    final isRemoteUserTyping = messageProvider.isRemoteUserTyping;
    final currentUserId = messageProvider.currentUserId;
    final isMuted = NotificationSettingsService.isChatMuted(widget.chatId);

    return Scaffold(
      appBar: AppBar(
        title: Text(_liveGroupName ?? widget.contactName, style: const TextStyle(fontSize: 16)),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (value) {
              if (value == 'mute') {
                NotificationSettingsService.toggleMuteChat(widget.chatId);
                final nowMuted = NotificationSettingsService.isChatMuted(widget.chatId);
                ApiService.setChatMuted(widget.chatId, nowMuted);
                setState(() {});
                SnackBarHelper.show(context, nowMuted ? 'Chat muted' : 'Chat unmuted');
              } else if (value == 'view_profile') {
                _viewProfile();
              } else if (value == 'remove_friend') {
                _confirmRemoveFriend();
              } else if (value == 'group_info') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => GroupInfoScreen(
                      chatId: widget.chatId,
                      groupName: _liveGroupName ?? widget.contactName,
                    ),
                  ),
                ).then((_) {
                  if (widget.isGroup) _loadGroupMembers();
                });
              } else if (value == 'leave_group') {
                _confirmLeaveGroup();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'mute',
                child: Text(isMuted ? 'Unmute Notifications' : 'Mute Notifications'),
              ),
              if (widget.isGroup) ...[
                const PopupMenuItem(
                  value: 'group_info',
                  child: Text('Group Info'),
                ),
                const PopupMenuItem(
                  value: 'leave_group',
                  child: Text('Leave Group', style: TextStyle(color: Colors.red)),
                ),
              ] else ...[
                const PopupMenuItem(
                  value: 'view_profile',
                  child: Text('View Profile'),
                ),
                const PopupMenuItem(
                  value: 'remove_friend',
                  child: Text('Remove Friend', style: TextStyle(color: Colors.red)),
                ),
              ],
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                isLoadingHistory
                    ? Center(child: CircularProgressIndicator(color: AppColors.primary))
                    : messages.isEmpty
                        ? const EmptyState(
                            icon: Icons.waving_hand_rounded,
                            title: 'No messages yet',
                            subtitle: 'Say hello and start the conversation!',
                          )
                        : ScrollablePositionedList.builder(
                            itemScrollController: _itemScrollController,
                            itemPositionsListener: _itemPositionsListener,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            // +1 for a trailing zero-height sentinel used to reliably
                            // jump to the true bottom (see _scrollToBottom / _jumpToInitialPosition).
                            itemCount: messages.length + 1,
                            itemBuilder: (context, index) {
                              if (index == messages.length) {
                                return const SizedBox.shrink();
                              }
                              final msg = messages[index];
                              final bool isMe = currentUserId != null && msg['sender_id'] == currentUserId;
                              final bool isDeleted = msg['is_deleted'] ?? false;
                              final String status = msg['status'] ?? 'sent';
                              // A message that hasn't been confirmed by the server yet has no
                              // real id — editing/deleting it doesn't make sense until confirmed.
                              final bool isConfirmed = status != 'sending' && status != 'failed';

                              return MessageBubble(
                                messageId: msg['id'] ?? '',
                                content: msg['content'] ?? '',
                                mediaUrl: msg['media_url'],
                                mediaType: msg['media_type'] ?? 'text',
                                isMe: isMe,
                                isDeleted: isDeleted,
                                timestamp: _formatTimestamp(msg['created_at']),
                                status: status,
                                isEdited: msg['is_edited'] ?? false,
                                replyTo: msg['reply_to'] is Map
                                    ? Map<String, dynamic>.from(msg['reply_to'] as Map)
                                    : null,
                                replyToSenderName: msg['reply_to'] is Map
                                    ? _replySenderLabel(Map<String, dynamic>.from(msg['reply_to'] as Map))
                                    : null,
                                senderName: (widget.isGroup && !isMe)
                                    ? (_memberNames[msg['sender_id']?.toString()] ?? 'Member')
                                    : null,
                                onEdit: (isMe && !isDeleted && isConfirmed)
                                    ? () => _editMessage(msg['id'] ?? '', msg['content'] ?? '')
                                    : null,
                                onDelete: (isMe && !isDeleted && isConfirmed)
                                    ? () => _confirmDeleteMessage(msg['id'] ?? '')
                                    : null,
                                onRetry: (isMe && status == 'failed')
                                    ? () => _retryMessage(msg['_tempId'] as String)
                                    : null,
                                onReply: (isConfirmed && !isDeleted) ? () => _startReply(msg) : null,
                              );
                            },
                          ),
                if (_showJumpToLatestButton)
                  Positioned(
                    bottom: 12,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Material(
                        color: AppColors.surface,
                        elevation: 3,
                        borderRadius: BorderRadius.circular(20),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () {
                            setState(() => _showJumpToLatestButton = false);
                            _scrollToBottom();
                          },
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.arrow_downward, size: 16, color: AppColors.primary),
                                SizedBox(width: 6),
                                Text(
                                  'More messages',
                                  style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SizeTransition(sizeFactor: animation, alignment: Alignment(-1.0, -1.0), child: child),
            ),
            child: isRemoteUserTyping
                ? const Padding(
                    key: ValueKey('typing'),
                    padding: EdgeInsets.only(top: 4),
                    child: TypingIndicatorBubble(),
                  )
                : const SizedBox.shrink(key: ValueKey('not_typing')),
          ),

          if (_replyingTo != null)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.cardBorder),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.softShadow,
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 32,
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Replying to ${_replySenderLabel(_replyingTo!)}',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppColors.primary),
                        ),
                        Text(
                          replyPreviewText(_replyingTo!),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: _cancelReply,
                  ),
                ],
              ),
            ),

          Container(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
            decoration: BoxDecoration(
              color: AppColors.surface,
              boxShadow: [
                BoxShadow(color: AppColors.floatingBarShadow, blurRadius: 12, offset: const Offset(0, -2)),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3F2F7),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        children: [
                          if (_isUploadingMedia)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                              ),
                            )
                          else if (_isRecording) ...[
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 10),
                              child: Icon(Icons.fiber_manual_record, color: Colors.red, size: 14),
                            ),
                            Expanded(
                              child: Text(
                                'Recording  ${_formatRecordingDuration(_recordingSeconds)}',
                                style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ] else ...[
                            IconButton(
                              icon: Icon(Icons.photo_outlined, color: AppColors.primary),
                              onPressed: () => _pickAndSendMedia(ImageSource.gallery),
                              tooltip: 'Send from Gallery',
                            ),
                            IconButton(
                              icon: Icon(Icons.photo_camera_outlined, color: AppColors.primary),
                              onPressed: () => _pickAndSendMedia(ImageSource.camera),
                              tooltip: 'Take Photo or Video',
                            ),
                            Expanded(
                              child: TextField(
                                controller: _messageController,
                                onChanged: _handleTyping,
                                minLines: 1,
                                maxLines: 5,
                                decoration: const InputDecoration(
                                  hintText: 'Type a message...',
                                  border: InputBorder.none,
                                  filled: false,
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                                ),
                              ),
                            ),
                          ],
                          IconButton(
                            icon: Icon(_isRecording ? Icons.stop_circle : Icons.mic_none, color: _isRecording ? Colors.red : AppColors.primary),
                            onPressed: _isUploadingMedia ? null : _toggleRecording,
                            tooltip: _isRecording ? 'Stop Recording' : 'Record Audio',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          AppColors.primary,
                          AppColors.darken(AppColors.primary),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.35),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.send_rounded, color: Colors.white),
                      onPressed: () => _sendMessage(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
