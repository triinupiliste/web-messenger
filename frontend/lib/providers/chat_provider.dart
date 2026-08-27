import 'dart:async';
import 'package:flutter/material.dart';
import '../constants/socket_events.dart';
import '../models/chat_model.dart';
import '../services/api_service.dart';
import '../services/socket_service.dart';
import '../services/notification_service.dart';
import '../utils/json_utils.dart';

class ChatProvider with ChangeNotifier {
  List<ChatModel> _chats = [];
  bool _isLoading = false;
  // The socket generation (see SocketService.socketGeneration) our listeners are
  // currently registered against; -1 means "not attached to anything yet".
  int _attachedSocketGeneration = -1;
  String? _currentUserId;

  // Chat swiped-to-delete but still within its "Undo" window; only persisted once the timer fires.
  ChatModel? _pendingDeleteChat;
  int? _pendingDeleteIndex;
  Timer? _pendingDeleteTimer;

  // Stored so dispose()/re-attachment can unregister exactly these callbacks.
  // Not `final`: a different user logging in within the same app session gets a
  // brand new underlying socket, so these get re-created and re-registered then.
  late void Function(dynamic) _onReceiveMessage;
  late void Function(dynamic) _onMessageDeleted;
  late void Function(dynamic) _onMessageEdited;
  late void Function(dynamic) _onFriendRemoved;
  late void Function(dynamic) _onInviteResponded;
  late void Function(dynamic) _onChatRead;
  late void Function(dynamic) _onProfileUpdated;
  late void Function(dynamic) _onGroupMemberRemoved;
  late void Function(dynamic) _onGroupRenamed;
  late void Function(dynamic) _onConnect;

  List<ChatModel> get chats => _chats;
  bool get isLoading => _isLoading;

  // Total unread message count across all chats, used for the badge on the
  // bottom nav's Chats icon.
  int get totalUnreadCount => _chats.fold(0, (sum, c) => sum + c.unreadCount);

  ChatProvider() {
    _initGlobalSocketListener();
  }

  Future<void> fetchChats() async {
    _isLoading = true;
    notifyListeners();

    // Retry attaching in case the socket wasn't ready yet at app startup.
    _initGlobalSocketListener();
    unawaited(_ensureCurrentUserId());

    try {
      final data = await ApiService.getChats();
      _chats = data.map((json) => ChatModel.fromJson(json)).toList();
      _sortChats();

      // Re-seed the mute cache from the server so it survives app restarts.
      for (final chat in _chats) {
        NotificationSettingsService.setChatMuted(chat.chatId, chat.isMuted);
      }

      // Join every one of this account's chat rooms, not just ones actually opened
      // this session — otherwise a chat that isn't currently open in THIS browser
      // tab/window never receives its receive_message/chat_read broadcasts (those
      // are scoped to the chat's room), so this session's badge/preview for it
      // would only ever catch up on a manual refresh.
      _joinAllChatRooms();
    } catch (e) {
      debugPrint('Error fetching chats: $e');
    }

    _isLoading = false;
    notifyListeners();
  }

  // Same as fetchChats(), but doesn't toggle isLoading — used for background
  // refreshes (e.g. after the chat's last message gets deleted) where
  // replacing the whole list with a spinner would be a jarring flash.
  Future<void> _refreshChatsQuietly() async {
    try {
      final data = await ApiService.getChats();
      _chats = data.map((json) => ChatModel.fromJson(json)).toList();
      _sortChats();
      notifyListeners();
    } catch (e) {
      debugPrint('Error refreshing chats: $e');
    }
  }

  void _sortChats() {
    _chats.sort((a, b) {
      final timeA = a.lastMessageTime ?? DateTime(2000);
      final timeB = b.lastMessageTime ?? DateTime(2000);
      return timeB.compareTo(timeA);
    });
  }

  Future<void> _ensureCurrentUserId() async {
    if (_currentUserId != null) return;
    try {
      final profile = await ApiService.getProfile();
      _currentUserId = extractUserId(profile);
    } catch (e) {
      debugPrint('Error fetching current user id: $e');
    }
  }

  // Listen globally for incoming messages to update the chat list preview and sorting.
  // Safe to call repeatedly: it's a no-op unless the underlying socket has changed
  // since we last attached (e.g. a different user logged in within this same app
  // session, replacing the socket instance our listeners were bound to).
  void _initGlobalSocketListener() {
    if (_attachedSocketGeneration == SocketService.socketGeneration) return;
    _detachSocketListeners();
    try {
      _onReceiveMessage = (data) {
        final chatId = data['chat_id'] ?? data['chatId'];
        final index = _chats.indexWhere((c) => c.chatId == chatId);
        final senderId = data['sender_id']?.toString();
        final isFromMe = _currentUserId != null && senderId == _currentUserId;
        // If this chat is open on screen it's already marked read, so don't count it as unread.
        final chatIsActive = ActiveChatTracker.isChatActive(chatId?.toString() ?? '');

        if (index != -1) {
          final existing = _chats[index];
          _chats[index] = ChatModel(
            chatId: existing.chatId,
            isGroup: existing.isGroup,
            contactId: existing.contactId,
            contactName: existing.contactName,
            contactAvatar: existing.contactAvatar,
            memberCount: existing.memberCount,
            lastMessageId: data['id']?.toString(),
            lastMessage: data['content'],
            lastMessageType: data['media_type'] ?? data['mediaType'],
            lastMessageTime: data['created_at'] != null 
                ? DateTime.parse(data['created_at']) 
                : DateTime.now(),
            lastMessageSenderId: data['sender_id'],
            // Force 0 while the chat is open (already read); otherwise bump if not from me.
            unreadCount: chatIsActive
                ? 0
                : (!isFromMe ? existing.unreadCount + 1 : existing.unreadCount),
            isArchived: false, // a new message un-archives the chat, matching the server

            isMuted: existing.isMuted,
          );
          _sortChats();
          notifyListeners();
        } else {
          // If it's a brand new chat, fetch the full list again
          fetchChats();
        }
      };
      SocketService.on(SocketEvents.receiveMessage, _onReceiveMessage);

      // The chat list preview only shows non-deleted messages (mirroring the
      // backend query), so if the message that was just deleted is the one
      // currently shown as this chat's preview, refetch to reveal whatever
      // the new most-recent (non-deleted) message actually is — the client
      // doesn't have that older message's content cached locally.
      _onMessageDeleted = (data) {
        final chatId = (data['chat_id'] ?? data['chatId'])?.toString();
        final messageId = data['id']?.toString();
        if (chatId == null) return;
        final index = _chats.indexWhere((c) => c.chatId == chatId);
        if (index == -1) return;
        if (_chats[index].lastMessageId != null && _chats[index].lastMessageId == messageId) {
          _refreshChatsQuietly();
        }
      };
      SocketService.on(SocketEvents.messageDeleted, _onMessageDeleted);

      // Same idea as _onMessageDeleted, but simpler: an edit's payload already
      // carries the new content, so no refetch is needed — just patch the
      // preview text in place when the edited message is the one shown.
      _onMessageEdited = (data) {
        final chatId = (data['chat_id'] ?? data['chatId'])?.toString();
        final messageId = data['id']?.toString();
        if (chatId == null) return;
        final index = _chats.indexWhere((c) => c.chatId == chatId);
        if (index == -1) return;
        final existing = _chats[index];
        if (existing.lastMessageId == null || existing.lastMessageId != messageId) return;
        _chats[index] = ChatModel(
          chatId: existing.chatId,
          isGroup: existing.isGroup,
          contactId: existing.contactId,
          contactName: existing.contactName,
          contactAvatar: existing.contactAvatar,
          memberCount: existing.memberCount,
          lastMessageId: existing.lastMessageId,
          lastMessage: data['content'] ?? existing.lastMessage,
          lastMessageType: existing.lastMessageType,
          lastMessageTime: existing.lastMessageTime,
          lastMessageSenderId: existing.lastMessageSenderId,
          unreadCount: existing.unreadCount,
          isArchived: existing.isArchived,
          isMuted: existing.isMuted,
        );
        notifyListeners();
      };
      SocketService.on(SocketEvents.messageEdited, _onMessageEdited);

      // The other participant removed us as a friend; drop the chat live.
      _onFriendRemoved = (data) {
        final chatId = data['chatId'];
        final removed = _chats.any((c) => c.chatId == chatId);
        if (!removed) return;
        _chats.removeWhere((c) => c.chatId == chatId);
        notifyListeners();
      };
      SocketService.on(SocketEvents.friendRemoved, _onFriendRemoved);

      // If an invite we sent was accepted, a chat now exists on the backend; refresh to show it.
      _onInviteResponded = (data) {
        if (data['status'] == 'accepted') {
          fetchChats();
        }
      };
      SocketService.on(SocketEvents.inviteResponded, _onInviteResponded);

      // This account read a chat's messages in another session (e.g. a second
      // browser tab/window) — clear this chat's unread badge here too, instead
      // of leaving it stale until a manual refresh.
      _onChatRead = (data) {
        final chatId = data['chatId']?.toString();
        if (chatId != null) markChatRead(chatId);
      };
      SocketService.on(SocketEvents.chatRead, _onChatRead);

      // A contact changed their username/avatar; patch it into any chat we have with them.
      // Group chats always have an empty contactId, so this never matches a group by accident.
      _onProfileUpdated = (data) {
        final userId = extractUserId(data, 'userId');
        if (userId == null) return;
        final index = _chats.indexWhere((c) => !c.isGroup && c.contactId == userId);
        if (index == -1) return;
        final existing = _chats[index];
        _chats[index] = ChatModel(
          chatId: existing.chatId,
          isGroup: existing.isGroup,
          contactId: existing.contactId,
          contactName: data['username']?.toString() ?? existing.contactName,
          contactAvatar: data['avatar_url']?.toString() ?? existing.contactAvatar,
          memberCount: existing.memberCount,
          lastMessageId: existing.lastMessageId,
          lastMessage: existing.lastMessage,
          lastMessageType: existing.lastMessageType,
          lastMessageTime: existing.lastMessageTime,
          lastMessageSenderId: existing.lastMessageSenderId,
          unreadCount: existing.unreadCount,
          isArchived: existing.isArchived,
          isMuted: existing.isMuted,
        );
        notifyListeners();
      };
      SocketService.on(SocketEvents.profileUpdated, _onProfileUpdated);

      // We were removed from (or left) a group; drop it from the list live.
      // If someone else was removed, just refresh the member count via a refetch
      // isn't necessary for the chat list, so no action is needed there.
      _onGroupMemberRemoved = (data) {
        if (_currentUserId != null && data['userId']?.toString() == _currentUserId) {
          final chatId = data['chatId'];
          _chats.removeWhere((c) => c.chatId == chatId);
          notifyListeners();
        }
      };
      SocketService.on(SocketEvents.groupMemberRemoved, _onGroupMemberRemoved);

      // A group we're in was renamed; patch the display name live.
      _onGroupRenamed = (data) {
        final chatId = data['chatId'];
        final index = _chats.indexWhere((c) => c.chatId == chatId);
        if (index == -1) return;
        final existing = _chats[index];
        _chats[index] = ChatModel(
          chatId: existing.chatId,
          isGroup: existing.isGroup,
          contactId: existing.contactId,
          contactName: data['name']?.toString() ?? existing.contactName,
          contactAvatar: existing.contactAvatar,
          memberCount: existing.memberCount,
          lastMessageId: existing.lastMessageId,
          lastMessage: existing.lastMessage,
          lastMessageType: existing.lastMessageType,
          lastMessageTime: existing.lastMessageTime,
          lastMessageSenderId: existing.lastMessageSenderId,
          unreadCount: existing.unreadCount,
          isArchived: existing.isArchived,
          isMuted: existing.isMuted,
        );
        notifyListeners();
      };
      SocketService.on(SocketEvents.groupRenamed, _onGroupRenamed);

      // Rejoin every known chat room after a (re)connect — a dropped/replaced
      // connection loses prior room membership, so without this a session that
      // briefly disconnects would silently stop receiving live updates for
      // chats it isn't actively viewing until the next manual refresh.
      _onConnect = (_) => _joinAllChatRooms();
      SocketService.on(SocketEvents.connect, _onConnect);

      _attachedSocketGeneration = SocketService.socketGeneration;
    } catch (e) {
      debugPrint('Socket listener initialization deferred: $e');
    }
  }

  void _joinAllChatRooms() {
    for (final chat in _chats) {
      SocketService.joinChat(chat.chatId);
    }
  }

  // Unregisters from whatever socket generation we were previously attached to
  // (safe no-op the first time, before anything has ever been registered).
  void _detachSocketListeners() {
    if (_attachedSocketGeneration == -1) return;
    SocketService.off(SocketEvents.receiveMessage, _onReceiveMessage);
    SocketService.off(SocketEvents.messageDeleted, _onMessageDeleted);
    SocketService.off(SocketEvents.messageEdited, _onMessageEdited);
    SocketService.off(SocketEvents.friendRemoved, _onFriendRemoved);
    SocketService.off(SocketEvents.inviteResponded, _onInviteResponded);
    SocketService.off(SocketEvents.chatRead, _onChatRead);
    SocketService.off(SocketEvents.profileUpdated, _onProfileUpdated);
    SocketService.off(SocketEvents.groupMemberRemoved, _onGroupMemberRemoved);
    SocketService.off(SocketEvents.groupRenamed, _onGroupRenamed);
    SocketService.off(SocketEvents.connect, _onConnect);
  }

  // Optimistically zeroes a chat's local unread badge the instant it's opened,
  // instead of waiting for a future fetchChats()/receive_message to catch it up —
  // markChatMessagesRead() (called by MessageProvider when the chat loads) updates
  // the server, but doesn't by itself touch this provider's in-memory chat list.
  void markChatRead(String chatId) {
    final index = _chats.indexWhere((c) => c.chatId == chatId);
    if (index == -1 || _chats[index].unreadCount == 0) return;
    final existing = _chats[index];
    _chats[index] = ChatModel(
      chatId: existing.chatId,
      isGroup: existing.isGroup,
      contactId: existing.contactId,
      contactName: existing.contactName,
      contactAvatar: existing.contactAvatar,
      memberCount: existing.memberCount,
      lastMessageId: existing.lastMessageId,
      lastMessage: existing.lastMessage,
      lastMessageType: existing.lastMessageType,
      lastMessageTime: existing.lastMessageTime,
      lastMessageSenderId: existing.lastMessageSenderId,
      unreadCount: 0,
      isArchived: existing.isArchived,
      isMuted: existing.isMuted,
    );
    notifyListeners();
  }

  Future<void> toggleArchiveChat(String chatId) async {
    final index = _chats.indexWhere((c) => c.chatId == chatId);
    if (index == -1) return;

    final previousValue = _chats[index].isArchived;
    final newValue = !previousValue;

    // Optimistic update, rolled back on failure.
    _chats[index].isArchived = newValue;
    notifyListeners();

    try {
      await ApiService.setChatArchived(chatId, newValue);
    } catch (e) {
      debugPrint('Error updating chat archive state: $e');
      _chats[index].isArchived = previousValue;
      notifyListeners();
    }
  }

  // Removes from the list immediately; only tells the server once the undo window elapses.
  void deleteChat(String chatId) {
    final index = _chats.indexWhere((c) => c.chatId == chatId);
    if (index == -1) return;

    // If another delete was already pending, commit it immediately first.
    _commitPendingDelete();

    _pendingDeleteChat = _chats[index];
    _pendingDeleteIndex = index;
    _chats.removeAt(index);
    notifyListeners();

    _pendingDeleteTimer = Timer(const Duration(seconds: 5), _commitPendingDelete);
  }

  void _commitPendingDelete() {
    _pendingDeleteTimer?.cancel();
    _pendingDeleteTimer = null;
    final chat = _pendingDeleteChat;
    _pendingDeleteChat = null;
    _pendingDeleteIndex = null;
    if (chat == null) return;

    ApiService.setChatDeleted(chat.chatId, true).catchError((e) {
      debugPrint('Error deleting chat: $e');
    });
  }

  void undoDeleteChat() {
    _pendingDeleteTimer?.cancel();
    _pendingDeleteTimer = null;
    final chat = _pendingDeleteChat;
    final index = _pendingDeleteIndex;
    _pendingDeleteChat = null;
    _pendingDeleteIndex = null;
    if (chat == null || index == null) return;

    _chats.insert(index.clamp(0, _chats.length), chat);
    notifyListeners();
  }

  // Ends the friendship; no undo since this is already behind a confirmation dialog.
  Future<void> removeFriend(String chatId) async {
    final index = _chats.indexWhere((c) => c.chatId == chatId);
    final removedChat = index != -1 ? _chats[index] : null;
    if (index != -1) {
      _chats.removeAt(index);
      notifyListeners();
    }

    try {
      await ApiService.removeFriend(chatId);
    } catch (e) {
      if (removedChat != null) {
        _chats.insert(index.clamp(0, _chats.length), removedChat);
        notifyListeners();
      }
      rethrow;
    }
  }

  // Creates a new group chat with just the current user as a member/owner;
  // other members are added afterwards by sending them group invites.
  Future<String> createGroup(String name) async {
    final chatId = await ApiService.createGroup(name);
    await fetchChats();
    return chatId;
  }

  @override
  void dispose() {
    _detachSocketListeners();
    super.dispose();
  }
}