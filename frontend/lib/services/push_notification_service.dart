import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../screens/chat/chat_room_screen.dart';
import '../screens/invites/invites_screen.dart';
import 'api_service.dart';
import 'notification_service.dart';

const String _pushChannelId = 'messages';
const String _pushChannelName = 'Messages & Invites';

int _notificationIdForChat(String chatId) => chatId.hashCode;

const AndroidNotificationChannel _pushChannel = AndroidNotificationChannel(
  _pushChannelId,
  _pushChannelName,
  description: 'New chat messages and chat invites',
  importance: Importance.high,
);

// Shared by the foreground listener and background isolate handler so a chat's
// notification always gets the same stable id. Backend sends data-only messages
// (no top-level `notification` block), so this is the only place that displays them.
Future<void> _displayMessageNotification(
  FlutterLocalNotificationsPlugin plugin,
  Map<String, dynamic> data,
) async {
  final chatId = data['chatId'] as String?;
  if (data['type'] == 'message' && chatId != null && ActiveChatTracker.isChatActive(chatId)) {
    // Already visible live in the open chat — no need to also notify.
    return;
  }

  final title = data['title'] as String?;
  final body = data['body'] as String?;
  if (title == null || body == null) return;

  // Stable per-chat id so a newer message replaces the previous tray notification
  // instead of stacking, and can be cancelled later by chat id.
  final notificationId =
      data['type'] == 'message' && chatId != null ? _notificationIdForChat(chatId) : data.hashCode;

  await plugin.show(
    notificationId,
    title,
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        _pushChannelId,
        _pushChannelName,
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
    payload: jsonEncode(data),
  );
}

// Must be top-level/static — FCM runs this in a separate background isolate with
// its own plugin instance when a push arrives while the app is backgrounded/terminated.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  await plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_pushChannel);

  await _displayMessageNotification(plugin, message.data);
}

class PushNotificationService {
  // Lets notification-tap handlers navigate without needing a widget-tree
  // BuildContext (the app may be launching cold when a tap is handled).
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  static Future<void> init() async {
    // Push notifications aren't wired up for the web build yet (needs a
    // separate Firebase Web App + service worker) — the web app still
    // receives everything live via the socket connection while it's open.
    if (kIsWeb) return;

    // One-time setup only — must not gate token registration below, otherwise switching
    // accounts on the same device would leave the backend's fcm_token on the old user.
    if (!_initialized) {
      _initialized = true;

      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();

      await _localNotifications.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload;
          if (payload == null) return;
          _handleTap(Map<String, dynamic>.from(jsonDecode(payload)));
        },
      );

      await _localNotifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_pushChannel);

      // These are data-only FCM messages, so a cold start from tapping our tray
      // notification isn't recognized by onDidReceiveNotificationResponse or
      // getInitialMessage() — getNotificationAppLaunchDetails() is the only API that can.
      final launchDetails = await _localNotifications.getNotificationAppLaunchDetails();
      final launchPayload = launchDetails?.notificationResponse?.payload;
      if (launchDetails?.didNotificationLaunchApp == true && launchPayload != null) {
        _handleTap(Map<String, dynamic>.from(jsonDecode(launchPayload)));
      }

      messaging.onTokenRefresh.listen((token) => ApiService.registerFcmToken(token));

      // Android/FCM won't auto-show a system banner while the app is foregrounded,
      // so we display it ourselves unless it's for the chat already open on screen.
      FirebaseMessaging.onMessage.listen(_showForegroundNotification);

      // Backgrounded (not terminated) and the user tapped the system notification.
      FirebaseMessaging.onMessageOpenedApp.listen((message) => _handleTap(message.data));

      // The app was fully terminated and this notification tap launched it.
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        _handleTap(initialMessage.data);
      }
    }

    // Always (re-)register the current device's FCM token — must run on every
    // login, not just the first one for this app process.
    await _registerToken();
  }

  static Future<void> _registerToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await ApiService.registerFcmToken(token);
      }
    } catch (e) {
      // Non-fatal — e.g. Firebase not fully configured yet on this device.
      debugPrint('Failed to register FCM token: $e');
    }
  }

  static void _showForegroundNotification(RemoteMessage message) {
    _displayMessageNotification(_localNotifications, message.data);
  }

  // Dismisses the tray notification for a chat, e.g. once its messages have been read.
  static Future<void> cancelForChat(String chatId) async {
    await _localNotifications.cancel(_notificationIdForChat(chatId));
  }

  static void _handleTap(Map<String, dynamic> data) {
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;

    if (data['type'] == 'invite') {
      navigator.push(MaterialPageRoute(
        builder: (_) => const InvitesScreen(markSeenOnOpen: true),
      ));
    } else if (data['type'] == 'message') {
      final chatId = data['chatId'] as String?;
      if (chatId == null) return;
      navigator.push(MaterialPageRoute(
        builder: (_) => ChatRoomScreen(
          chatId: chatId,
          contactId: data['contactId'] as String? ?? '',
          contactName: data['contactName'] as String? ?? '',
        ),
      ));
    }
  }

  // Best-effort: stop this device from receiving further pushes once logged
  // out. Errors are ignored — logout must never be blocked by this.
  static Future<void> clearToken() async {
    if (kIsWeb) return;
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
  }
}
