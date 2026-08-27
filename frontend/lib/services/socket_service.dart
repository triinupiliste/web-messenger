import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:flutter/foundation.dart';
import '../config/server_config.dart';
import '../constants/socket_events.dart';
import 'storage_service.dart';

class SocketService {
  static io.Socket? _socket;
  // Token the current _socket was created with, so a different user logging in
  // on the same app process forces a fresh connection instead of reusing this one.
  static String? _connectedToken;

  // Bumped every time initSocket() creates a brand new underlying Socket.IO
  // client (e.g. a different user logs in within the same app session, or the
  // very first connection). Long-lived singleton listeners (ChatProvider,
  // InviteProvider) compare this against the generation they last attached to,
  // so they know to re-register on the new socket instead of staying silently
  // bound to a disposed one forever.
  static int socketGeneration = 0;

  // Non-nullable getter to keep all existing provider and screen calls working seamlessly
  static io.Socket get socket {
    if (_socket == null) {
      throw Exception('Socket has not been initialized. Call initSocket() first.');
    }
    return _socket!;
  }

  static Future<void> initSocket() async {
    final token = await StorageService.getToken();
    if (token == null) return;

    if (_socket != null && _socket!.connected && _connectedToken == token) return;

    // Not connected, or connected with a different user's token; tear down before reconnecting.
    if (_socket != null) {
      _socket!.dispose();
      _socket = null;
    }

    _connectedToken = token;
    _socket = io.io(serverBaseUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
      'auth': {'token': token},
    });
    socketGeneration++;

    final connected = Completer<void>();

    _socket!.onConnect((_) {
      debugPrint('Connected to Socket.io server');
      if (!connected.isCompleted) connected.complete();
    });

    _socket!.onConnectError((error) {
      debugPrint('Socket connect error: $error');
      if (!connected.isCompleted) connected.complete();
    });

    _socket!.onDisconnect((_) {
      debugPrint('Disconnected from Socket.io server');
    });

    _socket!.connect();

    // Wait for the connection to establish (or fail) so callers can rely on it being ready.
    await connected.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
  }

  static void joinChat(String chatId) {
    // socket.io-client buffers emits until connected, so no need to gate on `connected`—
    // doing so previously caused join/send calls to be silently dropped during reconnects.
    _socket?.emit(SocketEvents.joinChat, chatId);
  }

  static void sendMessage(String chatId, String content, {String? mediaUrl, String mediaType = 'text', String? tempId, String? replyToId}) {
    _socket?.emit(SocketEvents.sendMessage, {
      'chatId': chatId,
      'content': content,
      'mediaUrl': mediaUrl,
      'mediaType': mediaType,
      'tempId': tempId,
      'replyToId': replyToId,
    });
  }

  static void updateMessageStatus(String chatId, String messageId, String status) {
    _socket?.emit(SocketEvents.updateMessageStatus, {
      'chatId': chatId,
      'messageId': messageId,
      'status': status,
    });
  }

  static void sendTypingIndicator(String chatId, bool isTyping) {
    _socket?.emit(SocketEvents.typing, {'chatId': chatId, 'isTyping': isTyping});
  }

  static void disconnect() {
    try {
      if (_socket != null) {
        _socket!.disconnect();
        _socket = null;
        _connectedToken = null;
        debugPrint('Socket successfully disconnected and cleared.');
      }
    } catch (e) {
      debugPrint('Error disconnecting socket: $e');
    }
  }

  // Safe no-op if the socket hasn't been initialized, so callers can unregister
  // listeners in dispose() without guarding against the throwing `socket` getter.
  static void off(String event, [void Function(dynamic)? handler]) {
    _socket?.off(event, handler);
  }

  static void on(String event, void Function(dynamic) handler) {
    _socket?.on(event, handler);
  }
}