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

  // Stored so dispose() can unregister exactly these callbacks; otherwise reopening
  // the same chat stacks duplicate listeners on the shared socket singleton.
  late final void Function(dynamic) _onConnect;
  late final void Function(dynamic) _onReceiveMessage;
  late final void Function(dynamic) _onErrorFeedbackMarksFailed;
  late final void Function(dynamic) _onUserTyping;
  late final void Function(dynamic) _onMessageEdited;
  late final void Function(dynamic) _onMessageDeleted;
  late final void Function(dynamic) _onMessagesRead;
  late final void Function(dynamic) _onPollUpdated;

  // Joins the chat room, registers all real-time listeners, and loads
  // persisted history. Call once, right after construction.
  Future<void> init() async {
    // Catch up on read-receipts for messages that arrived while backgrounded
    // (deliberately not marked read then, since the user wasn't looking at them).
    AppLifecycleTracker.addForegroundListener(_onAppForegrounded);

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

        // Only mark 'read' if the app is actually foregrounded right now — this screen
        // can stay mounted while backgrounded, in which case it hasn't really been seen.
        if (AppLifecycleTracker.isForeground) {
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

    // When the other participant reads this chat, mark my sent messages 'read'.
    _onMessagesRead = (data) {
      if (data['chatId'] != chatId) return;
      // If I'm the one who just read the chat, my own sent messages weren't affected.
      if (_currentUserId != null && data['readerId'] == _currentUserId) return;
      var changed = false;
      for (final m in _messages) {
        if (m['sender_id'] == _currentUserId && m['status'] != 'read') {
          m['status'] = 'read';
          changed = true;
        }
      }
      if (changed) notifyListeners();
    };
    SocketService.on(SocketEvents.messagesRead, _onMessagesRead);

    _onPollUpdated = (data) {
      final poll = Map<String, dynamic>.from(data as Map);
      final pollId = poll['id']?.toString();
      if (pollId == null) return;
      _polls[pollId] = poll;
      notifyListeners();
    };
    SocketService.on(SocketEvents.pollUpdated, _onPollUpdated);

    await _loadHistory();
  }

  // Fetches a poll's live detail (question, options, tallies) if not already
  // cached; called by the poll bubble the first time it's rendered.
  Future<void> loadPoll(String pollId) async {
    if (_polls.containsKey(pollId)) return;
    try {
      final poll = await ApiService.getPoll(pollId);
      _polls[pollId] = poll;
      notifyListeners();
    } catch (_) {
      // Left uncached — the bubble stays in its loading state and can retry.
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
    ApiService.markChatMessagesRead(chatId);
    PushNotificationService.cancelForChat(chatId);
  }

  @override
  void dispose() {
    AppLifecycleTracker.removeForegroundListener(_onAppForegrounded);
    SocketService.off(SocketEvents.connect, _onConnect);
    SocketService.off(SocketEvents.receiveMessage, _onReceiveMessage);
    SocketService.off(SocketEvents.errorFeedback, _onErrorFeedbackMarksFailed);
    SocketService.off(SocketEvents.userTyping, _onUserTyping);
    SocketService.off(SocketEvents.messageEdited, _onMessageEdited);
    SocketService.off(SocketEvents.messageDeleted, _onMessageDeleted);
    SocketService.off(SocketEvents.messagesRead, _onMessagesRead);
    SocketService.off(SocketEvents.pollUpdated, _onPollUpdated);
    _typingTimer?.cancel();
    for (final timer in _pendingSendTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }
}
