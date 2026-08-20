import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../config/server_config.dart';
import 'storage_service.dart';

// MultipartFile.fromPath() doesn't infer content-type from the extension and
// defaults to application/octet-stream, which the backend's avatar upload
// endpoint rejects based on mimetype.
MediaType? _imageContentTypeForPath(String path) {
  final extension = path.split('.').last.toLowerCase();
  switch (extension) {
    case 'jpg':
    case 'jpeg':
      return MediaType('image', 'jpeg');
    case 'png':
      return MediaType('image', 'png');
    default:
      return null;
  }
}

// Thrown when the backend reports this token is no longer the active session
// (signed in on another device). Callers should log out locally instead of
// showing a generic error.
class SessionInvalidatedException implements Exception {
  final String message;
  SessionInvalidatedException(this.message);

  @override
  String toString() => message;
}

class ApiService {
  static const String baseUrl = '$serverBaseUrl/api';

  static const Map<String, String> ngrokHeader = {
    'ngrok-skip-browser-warning': 'true',
  };

  // Sent on login so the backend can label this device/browser in the
  // account's "Active sessions" list (see multi-session support).
  static String get _currentPlatform => kIsWeb ? 'web' : 'mobile';

  static String get _currentDeviceName {
    if (kIsWeb) return 'Web Browser';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'Android Device';
      case TargetPlatform.iOS:
        return 'iPhone/iPad';
      default:
        return 'Device';
    }
  }

  // ngrok's free tier serves an HTML interstitial page to non-browser requests
  // without this header, breaking JSON parsing. Exposed publicly so other
  // services fetching media URLs directly can send it too.
  static const Map<String, String> _ngrokHeader = ngrokHeader;

  static Future<Map<String, String>> _getHeaders() async {
    final token = await StorageService.getToken();
    return {
      'Content-Type': 'application/json',
      ..._ngrokHeader,
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // Native media widgets (Image.network, VideoPlayerController, etc.) can't attach an
  // Authorization header, so the token is appended as a query param instead. Backend
  // stores media as paths relative to itself (host can change between ngrok restarts);
  // old rows with a full absolute URL are left as-is.
  static String mediaUrl(String url) {
    final absoluteUrl = url.startsWith('http://') || url.startsWith('https://')
        ? url
        : '$serverBaseUrl$url';
    final token = StorageService.cachedToken;
    if (token == null || token.isEmpty) return absoluteUrl;
    final uri = Uri.tryParse(absoluteUrl);
    if (uri == null) return absoluteUrl;
    final query = Map<String, String>.from(uri.queryParameters)..['token'] = token;
    return uri.replace(queryParameters: query).toString();
  }

  // --- AUTHENTICATION ---
  static Future<Map<String, dynamic>> register(
      String username, String email, String password) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/register'),
      headers: {'Content-Type': 'application/json', ..._ngrokHeader},
      body: jsonEncode(
          {'username': username, 'email': email, 'password': password}),
    );
    return jsonDecode(response.body);
  }

  static Future<Map<String, dynamic>> login(
      String email, String password) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/login'),
      headers: {'Content-Type': 'application/json', ..._ngrokHeader},
      body: jsonEncode({
        'email': email,
        'password': password,
        'platform': _currentPlatform,
        'deviceName': _currentDeviceName,
      }),
    );
    final data = jsonDecode(response.body);
    if (response.statusCode == 200 && data['token'] != null) {
      await StorageService.setToken(data['token']);
    }
    return data;
  }

  static Future<Map<String, dynamic>> resendVerificationEmail(
      String email) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/resend-verification'),
      headers: {'Content-Type': 'application/json', ..._ngrokHeader},
      body: jsonEncode({'email': email.trim()}),
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(data['error'] ?? 'Failed to send verification email');
    }
    return data;
  }

  static Future<Map<String, dynamic>> requestPasswordReset(String email) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/request-password-reset'),
      headers: {'Content-Type': 'application/json', ..._ngrokHeader},
      body: jsonEncode({'email': email.trim()}),
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(data['error'] ?? 'Failed to request password reset');
    }
    return data;
  }

  // --- SESSIONS (multi-device login / selective logout) ---

  // Signs out this device's own session server-side, so it stops appearing
  // as "active" to the account's other devices. Best-effort: local logout
  // must proceed even if this call fails (e.g. no network).
  static Future<void> logout() async {
    try {
      final headers = await _getHeaders();
      await http
          .post(Uri.parse('$baseUrl/auth/logout'), headers: headers)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Ignored — see comment above.
    }
  }

  static Future<List<dynamic>> getSessions() async {
    final headers = await _getHeaders();
    final response =
        await http.get(Uri.parse('$baseUrl/auth/sessions'), headers: headers);
    final data = jsonDecode(response.body);
    if (response.statusCode == 200) {
      return (data is Map && data['sessions'] is List) ? data['sessions'] : [];
    }
    _throwIfSessionInvalidated(response);
    throw Exception(data['error'] ?? 'Failed to load active sessions');
  }

  // Selective logout: signs out one specific device without affecting the
  // account's other active sessions.
  static Future<void> revokeSession(String sessionId) async {
    final headers = await _getHeaders();
    final response = await http.delete(
      Uri.parse('$baseUrl/auth/sessions/$sessionId'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      final data = jsonDecode(response.body);
      throw Exception(data['error'] ?? 'Failed to log out that device');
    }
  }

  // --- USER PROFILE & SEARCH ---
  static Future<Map<String, dynamic>> getProfile() async {
    final headers = await _getHeaders();
    final response =
        await http.get(Uri.parse('$baseUrl/users/profile'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    }
    _throwIfSessionInvalidated(response);
    throw Exception('Failed to fetch profile');
  }

  // Set once by AuthProvider at startup; invoked on SESSION_INVALIDATED from any
  // endpoint, so a forced logout happens even from callers that swallow errors broadly.
  static void Function(String message)? onSessionInvalidated;

  // Checks whether a 401 is specifically SESSION_INVALIDATED (see auth.middleware.ts)
  // and throws SessionInvalidatedException so AuthProvider can force a local logout.
  static void _throwIfSessionInvalidated(http.Response response) {
    if (response.statusCode != 401) return;
    try {
      final data = jsonDecode(response.body);
      if (data is Map && data['code'] == 'SESSION_INVALIDATED') {
        final message = data['error'] as String? ??
            'You have been logged out because your account was signed in on another device.';
        onSessionInvalidated?.call(message);
        throw SessionInvalidatedException(message);
      }
    } on SessionInvalidatedException {
      rethrow;
    } catch (_) {
      // Not JSON, or didn't match — fall through to the caller's generic error.
    }
  }

  // Fetches another user's public profile (username, email, avatar, about me).
  static Future<Map<String, dynamic>> getUserProfile(String userId) async {
    final headers = await _getHeaders();
    final response =
        await http.get(Uri.parse('$baseUrl/users/$userId'), headers: headers);
    final data = jsonDecode(response.body);
    if (response.statusCode == 200) {
      return Map<String, dynamic>.from(data);
    }
    throw Exception(data['error'] ?? 'Failed to fetch user profile');
  }

  static Future<Map<String, dynamic>> updateProfile({
    String? username,
    String? email,
    String? avatarUrl,
    String? aboutMe,
  }) async {
    final headers = await _getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/users/profile'),
      headers: headers,
      body: jsonEncode({
        if (username != null) 'username': username,
        if (email != null) 'email': email,
        'avatar_url': avatarUrl,
        'about_me': aboutMe,
      }),
    );
    final data = jsonDecode(response.body);
    if (response.statusCode == 200) {
      return Map<String, dynamic>.from(data['profile']);
    }
    throw Exception(data['error'] ?? 'Failed to update profile');
  }

  static Future<List<dynamic>> searchUsers(String query) async {
    if (query.trim().isEmpty) return [];

    final token = await StorageService.getToken();
    if (token == null || token.isEmpty) {
      throw Exception('Your session has expired. Please log in again.');
    }

    final response = await http.get(
      Uri.parse('$baseUrl/users/search?q=${Uri.encodeComponent(query.trim())}'),
      headers: {
        'Content-Type': 'application/json',
        ..._ngrokHeader,
        'Authorization': 'Bearer $token',
      },
    ).timeout(
      const Duration(seconds: 8),
      onTimeout: () => throw Exception(
        'The server could not be reached. Check the backend connection.',
      ),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data is List) return data;
      if (data is Map && data['users'] is List) return data['users'];
      return [];
    } else if (response.statusCode == 400) {
      return [];
    } else {
      final data = jsonDecode(response.body);
      throw Exception(data['error'] ?? 'Failed to search users');
    }
  }

  static Future<void> sendInvite(String recipientId) async {
    final token = await StorageService.getToken();
    final response = await http.post(
      Uri.parse('$baseUrl/invites'),
      headers: {
        'Content-Type': 'application/json',
        ..._ngrokHeader,
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'receiverId': recipientId
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      final data = jsonDecode(response.body);
      throw Exception(data['error'] ?? 'Failed to send invite');
    }
  }

  static Future<Map<String, dynamic>> getInvitations() async {
    final token = await StorageService.getToken();
    final response = await http.get(
      Uri.parse('$baseUrl/invites'),
      headers: {
        'Content-Type': 'application/json',
        ..._ngrokHeader,
        'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data is Map<String, dynamic>) {
        return {
          'incoming': data['incoming'] ?? [],
          'outgoing': data['outgoing'] ?? [],
        };
      }
    }

    final data = jsonDecode(response.body);
    throw Exception(data['error'] ?? 'Failed to load invitations');
  }

  static Future<void> respondToInvite(String inviteId, String status) async {
    final token = await StorageService.getToken();
    final response = await http.post(
      Uri.parse('$baseUrl/invites/respond'),
      headers: {
        'Content-Type': 'application/json',
        ..._ngrokHeader,
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode(
          {'inviteId': inviteId, 'status': status}), // 'accepted' or 'declined'
    );

    if (response.statusCode != 200) {
      final data = jsonDecode(response.body);
      throw Exception(data['error'] ?? 'Failed to respond to invite');
    }
  }

  // --- CHATS & INVITATIONS ---
  static Future<List<dynamic>> getChats() async {
    final headers = await _getHeaders();
    final response =
        await http.get(Uri.parse('$baseUrl/chats'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    }
    _throwIfSessionInvalidated(response);
    return [];
  }

  static Future<List<dynamic>> getMessages(String chatId) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('$baseUrl/chats/$chatId/messages'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data is List) return data;
    }
    _throwIfSessionInvalidated(response);
    return [];
  }

  static Future<void> markChatMessagesRead(String chatId) async {
    final headers = await _getHeaders();
    await http.patch(
      Uri.parse('$baseUrl/chats/$chatId/read'),
      headers: headers,
    );
  }

  static Future<void> setChatMuted(String chatId, bool isMuted) async {
    final headers = await _getHeaders();
    await http.patch(
      Uri.parse('$baseUrl/chats/$chatId/mute'),
      headers: headers,
      body: jsonEncode({'isMuted': isMuted}),
    );
  }

  static Future<void> setChatArchived(String chatId, bool isArchived) async {
    final headers = await _getHeaders();
    await http.patch(
      Uri.parse('$baseUrl/chats/$chatId/archive'),
      headers: headers,
      body: jsonEncode({'isArchived': isArchived}),
    );
  }

  static Future<void> setChatDeleted(String chatId, bool isDeleted) async {
    final headers = await _getHeaders();
    await http.patch(
      Uri.parse('$baseUrl/chats/$chatId/delete'),
      headers: headers,
      body: jsonEncode({'isDeleted': isDeleted}),
    );
  }

  static Future<void> removeFriend(String chatId) async {
    final headers = await _getHeaders();
    await http.patch(
      Uri.parse('$baseUrl/chats/$chatId/remove-friend'),
      headers: headers,
    );
  }

  // --- PUSH NOTIFICATIONS ---
  static Future<void> registerFcmToken(String fcmToken) async {
    final headers = await _getHeaders();
    await http.put(
      Uri.parse('$baseUrl/users/fcm-token'),
      headers: headers,
      body: jsonEncode({'fcmToken': fcmToken}),
    );
  }

  // Uploads a local media file (image, video, or voice note) and returns its
  // publicly reachable URL so it can be sent as a message's mediaUrl.
  static Future<String> uploadMedia(File file) async {
    final token = await StorageService.getToken();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/media/upload'),
    );
    request.headers.addAll(_ngrokHeader);
    if (token != null) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    request.files.add(await http.MultipartFile.fromPath('file', file.path));

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 200 || response.statusCode == 201) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['url'] as String;
    }

    final data = jsonDecode(response.body);
    throw Exception(data['error'] ?? 'Failed to upload media.');
  }

  // Uploads a profile picture. Unlike uploadMedia, the backend restricts this
  // endpoint to JPEG/PNG and a 5MB limit.
  static Future<String> uploadAvatar(File file) async {
    final token = await StorageService.getToken();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/media/avatar'),
    );
    request.headers.addAll(_ngrokHeader);
    if (token != null) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    request.files.add(await http.MultipartFile.fromPath(
      'file',
      file.path,
      contentType: _imageContentTypeForPath(file.path),
    ));

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 200 || response.statusCode == 201) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['url'] as String;
    }

    final data = jsonDecode(response.body);
    throw Exception(data['error'] ?? 'Failed to upload profile picture.');
  }
}
