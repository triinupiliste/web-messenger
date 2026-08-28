import 'package:flutter/material.dart';
import '../constants/socket_events.dart';
import '../services/api_service.dart';
import '../services/socket_service.dart';
import '../utils/json_utils.dart';

class InviteProvider with ChangeNotifier {
  List<dynamic> _incoming = [];
  List<dynamic> _outgoing = [];
  bool _isLoading = false;
  // The socket generation (see SocketService.socketGeneration) our listeners
  // are registered against; -1 means not attached yet.
  int _attachedSocketGeneration = -1;

  // Incoming invite ids the user has already looked at. Drives the badge on
  // the bottom nav icon.
  final Set<String> _seenInviteIds = {};

  // Stored so dispose()/re-attachment can unregister these exact callbacks.
  // Not `final`: a different user logging in gets a new socket, recreating these.
  late void Function(dynamic) _onNewInvite;
  late void Function(dynamic) _onInviteResponded;
  late void Function(dynamic) _onProfileUpdated;

  List<dynamic> get incoming => _incoming;
  List<dynamic> get outgoing => _outgoing;
  bool get isLoading => _isLoading;

  int get unseenCount =>
      _incoming.where((invite) => !_seenInviteIds.contains(_inviteId(invite))).length;

  String _inviteId(dynamic invite) => (invite['id'] ?? invite['_id'] ?? '').toString();

  Future<void> fetchInvites() async {
    _isLoading = true;
    notifyListeners();

    // Retry attaching in case the socket wasn't ready yet at app startup.
    _initGlobalSocketListener();

    try {
      final data = await ApiService.getInvitations();
      _incoming = data['incoming'] ?? [];
      _outgoing = data['outgoing'] ?? [];
    } catch (e) {
      debugPrint('Error fetching invites: $e');
    }
    _isLoading = false;
    notifyListeners();
  }

  // Marks every currently known incoming invite as seen, clearing the badge.
  void markIncomingSeen() {
    for (final invite in _incoming) {
      _seenInviteIds.add(_inviteId(invite));
    }
    notifyListeners();
  }

  // Listens globally so the Invites screen and nav badge update instantly on
  // new/responded invites. Cheap no-op unless the socket changed since attaching.
  void _initGlobalSocketListener() {
    if (_attachedSocketGeneration == SocketService.socketGeneration) return;
    _detachSocketListeners();
    try {
      _onNewInvite = (data) {
        final id = _inviteId(data);
        if (id.isEmpty || _incoming.any((invite) => _inviteId(invite) == id)) return;
        _incoming = [data, ..._incoming];
        notifyListeners();
      };
      SocketService.on(SocketEvents.newInvite, _onNewInvite);

      _onInviteResponded = (data) {
        final id = _inviteId(data);
        final index = _outgoing.indexWhere((invite) => _inviteId(invite) == id);
        if (index == -1) return;
        // Responded invites (accepted/declined) no longer show up in the
        // pending outgoing list, matching what a fresh fetch would return.
        _outgoing = List.of(_outgoing)..removeAt(index);
        notifyListeners();
      };
      SocketService.on(SocketEvents.inviteResponded, _onInviteResponded);

      // A sender/recipient we have a pending invite with changed their username/avatar.
      _onProfileUpdated = (data) {
        final userId = extractUserId(data, 'userId');
        if (userId == null) return;
        var changed = false;

        _incoming = _incoming.map((invite) {
          final sender = invite['sender'];
          if (sender is Map && sender['id']?.toString() == userId) {
            changed = true;
            final updatedSender = Map<String, dynamic>.from(sender);
            if (data['username'] != null) updatedSender['username'] = data['username'];
            if (data['avatar_url'] != null) updatedSender['avatar_url'] = data['avatar_url'];
            return {...Map<String, dynamic>.from(invite), 'sender': updatedSender};
          }
          return invite;
        }).toList();

        _outgoing = _outgoing.map((invite) {
          final recipient = invite['recipient'];
          if (recipient is Map && recipient['id']?.toString() == userId) {
            changed = true;
            final updatedRecipient = Map<String, dynamic>.from(recipient);
            if (data['username'] != null) updatedRecipient['username'] = data['username'];
            if (data['avatar_url'] != null) updatedRecipient['avatar_url'] = data['avatar_url'];
            return {...Map<String, dynamic>.from(invite), 'recipient': updatedRecipient};
          }
          return invite;
        }).toList();

        if (changed) notifyListeners();
      };
      SocketService.on(SocketEvents.profileUpdated, _onProfileUpdated);

      _attachedSocketGeneration = SocketService.socketGeneration;
    } catch (e) {
      debugPrint('Socket listener initialization deferred: $e');
    }
  }

  // Unregisters from whatever socket generation we were previously attached to
  // (safe no-op the first time, before anything has ever been registered).
  void _detachSocketListeners() {
    if (_attachedSocketGeneration == -1) return;
    SocketService.off(SocketEvents.newInvite, _onNewInvite);
    SocketService.off(SocketEvents.inviteResponded, _onInviteResponded);
    SocketService.off(SocketEvents.profileUpdated, _onProfileUpdated);
  }

  Future<void> respondToInvite(String inviteId, String status) async {
    await ApiService.respondToInvite(inviteId, status);
    // Remove it immediately rather than waiting on the refresh below, so it can't be
    // responded to twice if that call is slow or fails.
    _incoming = _incoming.where((invite) => _inviteId(invite) != inviteId).toList();
    notifyListeners();
    await fetchInvites();
  }

  @override
  void dispose() {
    _detachSocketListeners();
    super.dispose();
  }
}
