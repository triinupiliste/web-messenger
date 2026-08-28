import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../config/server_config.dart';
import 'storage_service.dart';

// MultipartFile.fromBytes() doesn't infer content-type from a filename and
// defaults to application/octet-stream, which the backend's upload endpoint
// rejects based on mimetype.
MediaType? _imageContentTypeForFilename(String filename) {
  final extension = filename.split('.').last.toLowerCase();
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

// Thrown when the backend reports this token's session was invalidated
// (signed in elsewhere). Callers should log out locally instead of showing
// a generic error.
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

  // Sent on login so the backend can label this device in the account's
  // "Active sessions" list.
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

  // ngrok's free tier serves an HTML interstitial to non-browser requests
  // without this header, breaking JSON parsing.
  static const Map<String, String> _ngrokHeader = ngrokHeader;

  static Future<Map<String, String>> _getHeaders() async {
    final token = await StorageService.getToken();
    return {
      'Content-Type': 'application/json',
      ..._ngrokHeader,
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // Native media widgets can't attach an Authorization header, so the token
  // is appended as a query param instead. Old rows with a full absolute URL
  // are left as-is.
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

  // If [chatId] is given, this sends a group invite (asking the recipient to
  // join that existing group chat) instead of a 1:1 friend invite.
  static Future<void> sendInvite(String recipientId, {String? chatId}) async {
    final token = await StorageService.getToken();
    final response = await http.post(
      Uri.parse('$baseUrl/invites'),
      headers: {
        'Content-Type': 'application/json',
        ..._ngrokHeader,
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'receiverId': recipientId,
        if (chatId != null) 'chatId': chatId,
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

  // Server decrypts each message before matching (content uses a random IV
  // per message, so it can't be filtered in SQL). Returns matches in
  // chronological order plus the true total match count.
  static Future<Map<String, dynamic>> searchMessages(String chatId, String query) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('$baseUrl/chats/$chatId/search?q=${Uri.encodeComponent(query)}'),
      headers: headers,
    );
    final data = jsonDecode(response.body);
    if (response.statusCode == 200) {
      return {
        'results': (data['results'] as List?) ?? [],
        'total': (data['total'] as num?)?.toInt() ?? 0,
      };
    }
    throw Exception(data['error'] ?? 'Failed to search messages');
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

  // --- GROUP CHATS ---

  // Creates a new group chat (with the current user as its owner) and returns its chatId.
  static Future<String> createGroup(String name) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/chats/group'),
      headers: headers,
      body: jsonEncode({'name': name}),
    );
    final data = jsonDecode(response.body);
    if (response.statusCode == 201) {
      return data['chatId'] as String;
    }
    throw Exception(data['error'] ?? 'Failed to create group');
  }

  static Future<List<dynamic>> getGroupMembers(String chatId) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('$baseUrl/chats/$chatId/members'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data is List) return data;
    }
    final data = jsonDecode(response.body);
    throw Exception(data['error'] ?? 'Failed to fetch group members');
  }

  // Removes a member from a group; pass the current user's own id to leave the group.
  static Future<void> removeGroupMember(String chatId, String userId) async {
    final headers = await _getHeaders();
    final response = await http.delete(
      Uri.parse('$baseUrl/chats/$chatId/members/$userId'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      final data = jsonDecode(response.body);
      throw Exception(data['error'] ?? 'Failed to remove group member');
    }
  }

  static Future<void> renameGroup(String chatId, String name) async {
    final headers = await _getHeaders();
    final response = await http.patch(
      Uri.parse('$baseUrl/chats/$chatId/name'),
      headers: headers,
      body: jsonEncode({'name': name}),
    );
    if (response.statusCode != 200) {
      final data = jsonDecode(response.body);
      throw Exception(data['error'] ?? 'Failed to rename group');
    }
  }

  // --- POLLS ---

  // Creates the poll's DB rows and returns its detail. Caller still needs to
  // send the actual chat message via the socket 'send_message' event
  // (mediaType: 'poll', mediaUrl: pollId).
  static Future<Map<String, dynamic>> createPoll(
    String chatId,
    String question,
    List<String> options, {
    bool isAnonymous = false,
    bool allowMultipleAnswers = false,
  }) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/polls'),
      headers: headers,
      body: jsonEncode({
        'chatId': chatId,
        'question': question,
        'options': options,
        'isAnonymous': isAnonymous,
        'allowMultipleAnswers': allowMultipleAnswers,
      }),
    );
    final data = jsonDecode(response.body);
    if (response.statusCode == 201) {
      return Map<String, dynamic>.from(data);
    }
    throw Exception(data['error'] ?? 'Failed to create poll');
  }

  static Future<Map<String, dynamic>> getPoll(String pollId) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('$baseUrl/polls/$pollId'),
      headers: headers,
    );
    final data = jsonDecode(response.body);
    if (response.statusCode == 200) {
      return Map<String, dynamic>.from(data);
    }
    throw Exception(data['error'] ?? 'Failed to fetch poll');
  }

  // Replaces the current user's vote(s) with the given option ids; pass an
  // empty list to retract their vote entirely.
  static Future<Map<String, dynamic>> votePoll(String pollId, List<String> optionIds) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/polls/$pollId/vote'),
      headers: headers,
      body: jsonEncode({'optionIds': optionIds}),
    );
    final data = jsonDecode(response.body);
    if (response.statusCode == 200) {
      return Map<String, dynamic>.from(data);
    }
    throw Exception(data['error'] ?? 'Failed to record vote');
  }

  static Future<Map<String, dynamic>> closePoll(String pollId) async {
    final headers = await _getHeaders();
    final response = await http.patch(
      Uri.parse('$baseUrl/polls/$pollId/close'),
      headers: headers,
    );
    final data = jsonDecode(response.body);
    if (response.statusCode == 200) {
      return Map<String, dynamic>.from(data);
    }
    throw Exception(data['error'] ?? 'Failed to close poll');
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

  // Uploads a local media file and returns its publicly reachable URL. Takes
  // raw bytes rather than a dart:io File so this works on Flutter web, where
  // picked files only exist as blob: URLs. `filename` must keep its original
  // extension — the backend derives the stored extension/Content-Type from it.
  static Future<String> uploadMedia(Uint8List bytes, {required String filename}) async {
    final token = await StorageService.getToken();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/media/upload'),
    );
    request.headers.addAll(_ngrokHeader);
    if (token != null) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      bytes,
      filename: filename,
      contentType: _imageContentTypeForFilename(filename),
    ));

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 200 || response.statusCode == 201) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['url'] as String;
    }

    final data = jsonDecode(response.body);
    throw Exception(data['error'] ?? 'Failed to upload media.');
  }

  // Uploads a profile picture. Unlike uploadMedia, restricted to JPEG/PNG and
  // a 5MB limit; `bytes` are expected to already be JPEG-encoded (the cropper
  // always outputs JPEG).
  static Future<String> uploadAvatar(Uint8List bytes) async {
    final token = await StorageService.getToken();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/media/avatar'),
    );
    request.headers.addAll(_ngrokHeader);
    if (token != null) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      bytes,
      filename: 'avatar.jpg',
      contentType: MediaType('image', 'jpeg'),
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
