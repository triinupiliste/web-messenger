import 'dart:async';
import 'package:flutter/material.dart';
import '../constants/socket_events.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../services/push_notification_service.dart';
import '../services/socket_service.dart';
import '../utils/json_utils.dart';

// Owns the message list + real-time socket sync for a single chat room. Created
// fresh per ChatRoomScreen rather than registered globally, since this state
// is only needed by that one screen.
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
  // The socket generation (see SocketService.socketGeneration) our listeners
  // are registered against; -1 means not attached yet. This provider is cached
  // for the whole app session, so it must be able to re-attach if the socket
  // is ever replaced (e.g. a different user logs in).
  int _attachedSocketGeneration = -1;

  // Poll detail cache, keyed by pollId. Populated lazily by loadPoll() and kept
  // fresh by the 'poll_updated' broadcast.
  final Map<String, Map<String, dynamic>> _polls = {};

  Timer? _typingTimer;
  bool _isTyping = false;

  List<Map<String, dynamic>> get messages => _messages;
  bool get isRemoteUserTyping => _isRemoteUserTyping;
  bool get isLoadingHistory => _isLoadingHistory;
  String? get currentUserId => _currentUserId;

  Map<String, dynamic>? pollData(String pollId) => _polls[pollId];

  // Stored so dispose()/re-attachment can unregister these exact callbacks,
  // rather than stacking duplicate listeners on the shared socket. Not `final`:
  // re-attaching onto a replaced socket recreates them.
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
    // Catches up on read-receipts for messages that arrived while backgrounded.
    AppLifecycleTracker.addForegroundListener(_onAppForegrounded);

    ensureSocketListeners();

    await _loadHistory();
  }

  // (Re-)joins the chat room and (re-)registers listeners against whichever
  // socket is currently active. Cheap no-op unless the socket changed since we
  // last attached (e.g. a different user logged in). Called again by
  // MessageProviderRegistry each time this cached provider is reused.
  void ensureSocketListeners() {
    if (_attachedSocketGeneration == SocketService.socketGeneration) return;
    _detachSocketListeners();

    // socket.io-client buffers emits until connected, so no need to gate on
    // `connected` — doing so previously dropped join/send calls during reconnects.
    SocketService.joinChat(chatId);

    // Re-join whenever the socket (re)connects, e.g. after backgrounding drops it.
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

      // Tells the sender their message reached this device, so their tick
      // updates to 'delivered' regardless of foreground state.
      if (_currentUserId != null && incoming['sender_id'] != _currentUserId) {
        final messageId = incoming['id']?.toString();
        if (messageId != null && messageId.isNotEmpty) {
          SocketService.updateMessageStatus(chatId, messageId, 'delivered');
        }

        // Only mark 'read' if this chat is the one actually on screen right now
        // — this screen can stay mounted while a different chat/tab is visible.
        if (AppLifecycleTracker.isForeground && ActiveChatTracker.isChatActive(chatId)) {
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

    // Only broadcast once a message's status actually changes server-side:
    // 'delivered' on reaching another device, 'read' only once every group
    // participant has read it. Rank check guards against a late 'delivered'
    // echo overwriting an already-'read' status.
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

    // A participant's username changed; re-fetch cached polls to refresh
    // voter names rather than tracking which specific poll(s) they voted on.
    _onProfileUpdated = (_) {
      for (final pollId in _polls.keys.toList()) {
        _refreshPoll(pollId);
      }
    };
    SocketService.on(SocketEvents.profileUpdated, _onProfileUpdated);

    _attachedSocketGeneration = SocketService.socketGeneration;
  }

  // Unregisters from the previously attached socket generation (safe no-op
  // before anything has been registered).
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
  // shared by loadPoll() and the profile_updated handler above.
  Future<void> _refreshPoll(String pollId) async {
    try {
      final poll = await ApiService.getPoll(pollId);
      _polls[pollId] = poll;
      notifyListeners();
    } catch (_) {
      // Left as-is; the bubble stays in its loading state or shows stale data.
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
    // Only matters if this chat is the one actually on screen, otherwise every
    // chat opened this session would get marked read on any foreground.
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
