import 'dart:async';
import 'package:flutter/material.dart';
import '../constants/socket_events.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../services/push_notification_service.dart';
import '../services/socket_service.dart';
import '../utils/json_utils.dart';

// Owns the message list + real-time socket sync for a single chat room. Created fresh
// per ChatRoomScreen (not registered globally in main.dart) since this state is only
// needed by that one screen, unlike ChatProvider/InviteProvider.
class MessageProvider with ChangeNotifier {
  MessageProvider(this.chatId);

  final String chatId;

  // Messages sent but not yet confirmed by the server, keyed by tempId. If not
  // confirmed within this window, marked 'failed' so the user can retry.
  static const Duration _sendTimeout = Duration(seconds: 10);
  final Map<String, Timer> _pendingSendTimers = {};

  final List<Map<String, dynamic>> _messages = [];
  bool _isRemoteUserTyping = false;
  bool _isLoadingHistory = true;
  String? _currentUserId;
  // The socket generation (see SocketService.socketGeneration) our listeners are
  // currently registered against; -1 means "not attached to anything yet". This
  // provider is cached for the whole app session (see MessageProviderRegistry),
  // so it must be able to re-attach if the underlying socket is ever replaced
  // (e.g. a different user logs in within the same browser session).
  int _attachedSocketGeneration = -1;

  // Poll detail cache, keyed by pollId (a message's media_url when its
  // media_type is 'poll'). Populated lazily by loadPoll() and kept fresh by
  // the 'poll_updated' broadcast whenever anyone votes/closes it.
  final Map<String, Map<String, dynamic>> _polls = {};

  Timer? _typingTimer;
  bool _isTyping = false;

  List<Map<String, dynamic>> get messages => _messages;
  bool get isRemoteUserTyping => _isRemoteUserTyping;
  bool get isLoadingHistory => _isLoadingHistory;
  String? get currentUserId => _currentUserId;

  Map<String, dynamic>? pollData(String pollId) => _polls[pollId];

  // Stored so dispose()/re-attachment can unregister exactly these callbacks;
  // otherwise reopening the same chat stacks duplicate listeners on the shared
  // socket singleton. Not `final`: re-attaching onto a replaced socket recreates them.
  late void Function(dynamic) _onConnect;
  late void Function(dynamic) _onReceiveMessage;
  late void Function(dynamic) _onErrorFeedbackMarksFailed;
  late void Function(dynamic) _onUserTyping;
  late void Function(dynamic) _onMessageEdited;
  late void Function(dynamic) _onMessageDeleted;
  late void Function(dynamic) _onMessageStatusUpdated;
  late void Function(dynamic) _onPollUpdated;
  late void Function(dynamic) _onProfileUpdated;

  // Joins the chat room and registers all real-time listeners, then loads
  // persisted history. Call once, right after construction.
  Future<void> init() async {
    // Catch up on read-receipts for messages that arrived while backgrounded
    // (deliberately not marked read then, since the user wasn't looking at them).
    AppLifecycleTracker.addForegroundListener(_onAppForegrounded);

    ensureSocketListeners();

    await _loadHistory();
  }

  // (Re-)joins the chat room and (re-)registers all real-time listeners against
  // whichever socket is currently active. Safe — and cheap — to call repeatedly:
  // it's a no-op unless the underlying socket has changed since we last attached
  // (e.g. a different user logged in within this same app session, replacing the
  // socket instance our listeners/room-membership were bound to). Called again
  // by MessageProviderRegistry every time this cached provider is reused, since
  // it's kept alive for the whole app session rather than recreated per chat open.
  void ensureSocketListeners() {
    if (_attachedSocketGeneration == SocketService.socketGeneration) return;
    _detachSocketListeners();

    // socket.io-client buffers emits until connected, so no need to gate on `connected`—
    // doing so previously caused join/send calls to be silently dropped during reconnects.
    SocketService.joinChat(chatId);

    // Re-join whenever the socket (re)connects (e.g. after backgrounding drops it),
    // otherwise this chat stops receiving real-time updates until reopened.
    _onConnect = (_) {
      SocketService.joinChat(chatId);
    };
    SocketService.on(SocketEvents.connect, _onConnect);

    _onReceiveMessage = (data) {
      if (data['chat_id'] != chatId) return;
      final incoming = Map<String, dynamic>.from(data);
      final tempId = incoming['tempId']?.toString();

      final pendingIndex = tempId != null ? _messages.indexWhere((m) => m['_tempId'] == tempId) : -1;
      if (pendingIndex != -1) {
        // Confirms a message this device just sent; replace the optimistic placeholder.
        _messages[pendingIndex] = incoming;
      } else {
        _messages.add(incoming);
      }
      if (tempId != null) {
        _pendingSendTimers.remove(tempId)?.cancel();
      }
      notifyListeners();

      // Let the sender know their message reached this device live, so their tick
      // updates from 'sent' to 'delivered', regardless of whether we're foregrounded.
      if (_currentUserId != null && incoming['sender_id'] != _currentUserId) {
        final messageId = incoming['id']?.toString();
        if (messageId != null && messageId.isNotEmpty) {
          SocketService.updateMessageStatus(chatId, messageId, 'delivered');
        }

        // Only mark 'read' if this chat is actually the one on screen right now —
        // being foregrounded in general isn't enough, since this screen can stay
        // mounted (and its socket listeners live) while a different chat/tab is
        // what's actually visible, in which case this message hasn't really been seen.
        if (AppLifecycleTracker.isForeground && ActiveChatTracker.isChatActive(chatId)) {
          // Tell the backend immediately instead of waiting for this screen to reopen,
          // otherwise the chat list shows it as unread again once its count is re-fetched.
          ApiService.markChatMessagesRead(chatId);
          PushNotificationService.cancelForChat(chatId);
        }
      }
    };
    SocketService.on(SocketEvents.receiveMessage, _onReceiveMessage);

    // If the server rejects a send outright, mark it failed immediately instead
    // of waiting out the full send timeout.
    _onErrorFeedbackMarksFailed = (data) {
      final tempId = data['tempId']?.toString();
      if (tempId == null) return;
      _pendingSendTimers.remove(tempId)?.cancel();
      final index = _messages.indexWhere((m) => m['_tempId'] == tempId);
      if (index != -1) {
        _messages[index]['status'] = 'failed';
        notifyListeners();
      }
    };
    SocketService.on(SocketEvents.errorFeedback, _onErrorFeedbackMarksFailed);

    _onUserTyping = (data) {
      if (data['chatId'] == chatId) {
        _isRemoteUserTyping = data['isTyping'] == true;
        notifyListeners();
      }
    };
    SocketService.on(SocketEvents.userTyping, _onUserTyping);

    _onMessageEdited = (data) {
      final index = _messages.indexWhere((m) => m['id'] == data['id']);
      if (index != -1) {
        _messages[index]['content'] = data['content'];
        _messages[index]['is_edited'] = true;
        notifyListeners();
      }
    };
    SocketService.on(SocketEvents.messageEdited, _onMessageEdited);

    _onMessageDeleted = (data) {
      final index = _messages.indexWhere((m) => m['id'] == data['id']);
      if (index != -1) {
        _messages[index]['content'] = null;
        _messages[index]['media_url'] = null;
        _messages[index]['is_deleted'] = true;
        notifyListeners();
      }
    };
    SocketService.on(SocketEvents.messageDeleted, _onMessageDeleted);

    // The backend only broadcasts this once a message's status actually changes
    // server-side — 'delivered' when it reaches another participant's device, and
    // (for group chats) 'read' only once *every* other participant has read it,
    // not just the first one. A rank check guards against a late/out-of-order
    // 'delivered' echo overwriting an already-'read' status.
    _onMessageStatusUpdated = (data) {
      final messageId = data['messageId']?.toString();
      final status = data['status']?.toString();
      if (messageId == null || status == null) return;
      final index = _messages.indexWhere((m) => m['id'] == messageId);
      if (index == -1) return;
      const rank = {'sending': 0, 'failed': 0, 'sent': 1, 'delivered': 2, 'read': 3};
      if ((rank[status] ?? 0) <= (rank[_messages[index]['status']] ?? 0)) return;
      _messages[index]['status'] = status;
      notifyListeners();
    };
    SocketService.on(SocketEvents.messageStatusUpdated, _onMessageStatusUpdated);

    _onPollUpdated = (data) {
      final poll = Map<String, dynamic>.from(data as Map);
      final pollId = poll['id']?.toString();
      if (pollId == null) return;
      _polls[pollId] = poll;
      notifyListeners();
    };
    SocketService.on(SocketEvents.pollUpdated, _onPollUpdated);

    // A participant's username changed. Poll voter lists are resolved fresh
    // from the server on every fetch, so an already-cached poll just needs to
    // be re-fetched to pick up the new name — cheaper and simpler than trying
    // to figure out which specific cached poll(s) that user actually voted on.
    _onProfileUpdated = (_) {
      for (final pollId in _polls.keys.toList()) {
        _refreshPoll(pollId);
      }
    };
    SocketService.on(SocketEvents.profileUpdated, _onProfileUpdated);

    _attachedSocketGeneration = SocketService.socketGeneration;
  }

  // Unregisters from whatever socket generation we were previously attached to
  // (safe no-op the first time, before anything has ever been registered).
  void _detachSocketListeners() {
    if (_attachedSocketGeneration == -1) return;
    SocketService.off(SocketEvents.connect, _onConnect);
    SocketService.off(SocketEvents.receiveMessage, _onReceiveMessage);
    SocketService.off(SocketEvents.errorFeedback, _onErrorFeedbackMarksFailed);
    SocketService.off(SocketEvents.userTyping, _onUserTyping);
    SocketService.off(SocketEvents.messageEdited, _onMessageEdited);
    SocketService.off(SocketEvents.messageDeleted, _onMessageDeleted);
    SocketService.off(SocketEvents.messageStatusUpdated, _onMessageStatusUpdated);
    SocketService.off(SocketEvents.pollUpdated, _onPollUpdated);
    SocketService.off(SocketEvents.profileUpdated, _onProfileUpdated);
  }

  // Fetches a poll's live detail (question, options, tallies) if not already
  // cached; called by the poll bubble the first time it's rendered.
  Future<void> loadPoll(String pollId) async {
    if (_polls.containsKey(pollId)) return;
    await _refreshPoll(pollId);
  }

  // Unconditionally (re-)fetches a poll's detail and updates the cache —
  // shared by loadPoll() (first load) and the profile_updated handler above
  // (refreshing an already-cached poll so voter names stay current).
  Future<void> _refreshPoll(String pollId) async {
    try {
      final poll = await ApiService.getPoll(pollId);
      _polls[pollId] = poll;
      notifyListeners();
    } catch (_) {
      // Left as-is (possibly uncached, or stale) — the bubble stays in its
      // loading state or shows the previous data, and can retry later.
    }
  }

  // Replaces the current user's vote(s) on this poll; pass an empty list to
  // retract. Updates the cache immediately from the response instead of
  // waiting for the 'poll_updated' broadcast to come back around.
  Future<void> votePoll(String pollId, List<String> optionIds) async {
    final poll = await ApiService.votePoll(pollId, optionIds);
    _polls[pollId] = poll;
    notifyListeners();
  }

  // Creator-only: stops further voting on this poll.
  Future<void> closePoll(String pollId) async {
    final poll = await ApiService.closePoll(pollId);
    _polls[pollId] = poll;
    notifyListeners();
  }

  Future<void> _loadHistory() async {
    try {
      final profile = await ApiService.getProfile();
      _currentUserId = extractUserId(profile);

      final history = await ApiService.getMessages(chatId);
      _messages
        ..clear()
        ..addAll(history.whereType<Map>().map((m) => Map<String, dynamic>.from(m)));
      _isLoadingHistory = false;
      notifyListeners();

      // Mark the other participant's messages as read now that this chat is open.
      ApiService.markChatMessagesRead(chatId);
    } catch (e) {
      _isLoadingHistory = false;
      notifyListeners();
    }
  }

  void sendMessage(
    String content, {
    String? mediaUrl,
    String mediaType = 'text',
    Map<String, dynamic>? replyingTo,
  }) {
    if (content.trim().isEmpty && mediaUrl == null) return;

    final tempId = 'temp_${DateTime.now().microsecondsSinceEpoch}';

    _messages.add({
      '_tempId': tempId,
      'id': '',
      'chat_id': chatId,
      'sender_id': _currentUserId,
      'content': content,
      'media_url': mediaUrl,
      'media_type': mediaType,
      'status': 'sending',
      'is_edited': false,
      'is_deleted': false,
      'reply_to_id': replyingTo?['id'],
      'reply_to': replyingTo == null
          ? null
          : {
              'id': replyingTo['id'],
              'sender_id': replyingTo['sender_id'],
              'content': replyingTo['content'],
              'media_type': replyingTo['media_type'],
              'is_deleted': replyingTo['is_deleted'] ?? false,
            },
      'created_at': DateTime.now().toIso8601String(),
    });
    notifyListeners();

    SocketService.sendMessage(
      chatId,
      content,
      mediaUrl: mediaUrl,
      mediaType: mediaType,
      tempId: tempId,
      replyToId: replyingTo?['id']?.toString(),
    );
    _startSendTimeout(tempId);

    if (_isTyping) {
      _isTyping = false;
      SocketService.sendTypingIndicator(chatId, false);
    }
  }

  void _startSendTimeout(String tempId) {
    _pendingSendTimers[tempId]?.cancel();
    _pendingSendTimers[tempId] = Timer(_sendTimeout, () {
      _pendingSendTimers.remove(tempId);
      final index = _messages.indexWhere((m) => m['_tempId'] == tempId);
      if (index != -1 && _messages[index]['status'] == 'sending') {
        _messages[index]['status'] = 'failed';
        notifyListeners();
      }
    });
  }

  // Re-sends a message that previously failed, reusing the same tempId so the
  // retry still replaces this same bubble once confirmed.
  void retryMessage(String tempId) {
    final index = _messages.indexWhere((m) => m['_tempId'] == tempId);
    if (index == -1) return;

    final msg = _messages[index];
    msg['status'] = 'sending';
    notifyListeners();

    SocketService.sendMessage(
      chatId,
      msg['content'] ?? '',
      mediaUrl: msg['media_url'],
      mediaType: msg['media_type'] ?? 'text',
      tempId: tempId,
      replyToId: msg['reply_to_id']?.toString(),
    );
    _startSendTimeout(tempId);
  }

  void editMessage(String messageId, String newContent) {
    SocketService.socket.emit(SocketEvents.editMessage, {
      'messageId': messageId,
      'chatId': chatId,
      'newContent': newContent,
    });
  }

  void deleteMessage(String messageId) {
    SocketService.socket.emit(SocketEvents.deleteMessage, {
      'messageId': messageId,
      'chatId': chatId,
    });
  }

  void handleTyping() {
    if (!_isTyping) {
      _isTyping = true;
      SocketService.sendTypingIndicator(chatId, true);
    }

    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 2), () {
      _isTyping = false;
      SocketService.sendTypingIndicator(chatId, false);
    });
  }

  void _onAppForegrounded() {
    // Only this chat's own re-foreground matters if it's actually the one on
    // screen — otherwise every chat ever opened this session would get marked
    // read the instant the app/tab regains focus, regardless of what's visible.
    if (!ActiveChatTracker.isChatActive(chatId)) return;
    ApiService.markChatMessagesRead(chatId);
    PushNotificationService.cancelForChat(chatId);
  }

  @override
  void dispose() {
    AppLifecycleTracker.removeForegroundListener(_onAppForegrounded);
    _detachSocketListeners();
    _typingTimer?.cancel();
    for (final timer in _pendingSendTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }
}
