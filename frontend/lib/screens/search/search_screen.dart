import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/user_model.dart';
import '../../constants/socket_events.dart';
import '../../services/api_service.dart';
import '../../services/socket_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/json_utils.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/common/empty_state.dart';
import '../../widgets/common/user_avatar.dart';
import '../chat/chat_room_screen.dart';

class SearchScreen extends StatefulWidget {
  final Future<void> Function()? onInviteSent;

  // When set, this screen operates in "Add Members" mode for an existing
  // group chat instead of the default "find people to friend" mode: invites
  // sent here ask the recipient to join this group rather than become friends.
  final String? groupChatId;

  const SearchScreen({super.key, this.onInviteSent, this.groupChatId});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _sendingInviteTo = {};

  Timer? _searchDebounce;
  List<UserModel> _searchResults = [];
  bool _isLoading = false;
  bool _hasSearched = false;
  String? _searchError;
  int _searchVersion = 0;

  @override
  void initState() {
    super.initState();
    SocketService.socket.on(SocketEvents.profileUpdated, _handleProfileUpdated);
  }

  // A user currently shown in the results changed their username/avatar —
  // patch it in live instead of only showing it fresh on the next search.
  void _handleProfileUpdated(dynamic data) {
    if (!mounted) return;
    final userId = extractUserId(data as Map<String, dynamic>, 'userId');
    if (userId == null) return;
    final index = _searchResults.indexWhere((u) => u.id == userId);
    if (index == -1) return;
    final existing = _searchResults[index];
    setState(() {
      _searchResults[index] = UserModel(
        id: existing.id,
        username: data['username']?.toString() ?? existing.username,
        email: existing.email,
        avatarUrl: data['avatar_url']?.toString() ?? existing.avatarUrl,
        aboutMe: existing.aboutMe,
        relationshipStatus: existing.relationshipStatus,
        chatId: existing.chatId,
      );
    });
  }

  void _scheduleSearch(String value) {
    _searchDebounce?.cancel();
    final query = value.trim();
    final version = ++_searchVersion;

    if (query.isEmpty) {
      setState(() {
        _searchResults = [];
        _isLoading = false;
        _hasSearched = false;
        _searchError = null;
      });
      return;
    }

    // Only set loading if we don't already have results, preventing screen flashing/blanking
    if (_searchResults.isEmpty) {
      setState(() {
        _isLoading = true;
        _hasSearched = true;
        _searchError = null;
      });
    }

    _searchDebounce = Timer(
      const Duration(milliseconds: 400),
      () => _searchUsers(query, version),
    );
  }

  Future<void> _searchUsers(String query, int version) async {
    try {
      final response = await ApiService.searchUsers(query);

      // Discard this response if a newer search has started in the meantime.
      if (!mounted || version != _searchVersion) {
        return;
      }

      final users = <UserModel>[];
      for (final item in response) {
        if (item is Map) {
          final user = UserModel.fromJson(Map<String, dynamic>.from(item));
          if (user.id.isNotEmpty) users.add(user);
        }
      }

      setState(() {
        _searchResults = users;
        _isLoading = false;
        _searchError = null;
        _hasSearched = true;
      });
    } catch (error) {
      if (!mounted || version != _searchVersion) return;
      setState(() {
        // Keep previous results if an error occurs instead of wiping to blank
        _isLoading = false;
        _searchError = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _sendInvite(UserModel user) async {
    if (_sendingInviteTo.contains(user.id)) return;
    setState(() => _sendingInviteTo.add(user.id));

    try {
      await ApiService.sendInvite(user.id, chatId: widget.groupChatId);
      if (!mounted) return;

      _searchDebounce?.cancel();
      _searchVersion++;
      _searchController.clear();
      FocusScope.of(context).unfocus();
      setState(() {
        _searchResults = [];
        _isLoading = false;
        _hasSearched = false;
        _searchError = null;
      });

      await widget.onInviteSent?.call();
      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.check_circle, color: Colors.green, size: 48),
          title: const Text('Invitation sent'),
          content: Text(
            widget.groupChatId != null
                ? 'An invite to join the group was sent to ${user.username}.'
                : 'Your invitation to ${user.username} was sent and is pending.',
            textAlign: TextAlign.center,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      SnackBarHelper.show(context, error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() => _sendingInviteTo.remove(user.id));
      }
    }
  }

  Widget _buildUserCard(UserModel user) {
    final isSending = _sendingInviteTo.contains(user.id);
    final trimmedUsername = user.username.trim();
    final displayName = trimmedUsername.isEmpty ? 'Unknown user' : trimmedUsername;

    Widget actionWidget;
    // In "Add Members" mode we always show an Add button regardless of 1:1
    // friend/pending status — group membership is independent of that.
    if (widget.groupChatId != null) {
      actionWidget = ElevatedButton(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(84, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        onPressed: isSending ? null : () => _sendInvite(user),
        child: isSending
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text('Add'),
      );
    } else if (user.relationshipStatus == 'friends') {
      actionWidget = ElevatedButton(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(84, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        onPressed: user.chatId == null
            ? null
            : () {
                FocusScope.of(context).unfocus();
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatRoomScreen(
                      chatId: user.chatId!,
                      contactId: user.id,
                      contactName: displayName,
                    ),
                  ),
                );
              },
        child: const Text('Send Message'),
      );
    } else if (user.relationshipStatus == 'pending') {
      actionWidget = Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'Pending',
          style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w600),
        ),
      );
    } else {
      actionWidget = ElevatedButton(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(84, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        onPressed: isSending ? null : () => _sendInvite(user),
        child: isSending
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text('Invite'),
      );
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            UserAvatar(
              avatarUrl: user.avatarUrl,
              displayName: displayName,
              radius: 26,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    user.email,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            actionWidget,
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBody() {
    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    if (_searchError != null) {
      return Center(
        child: Text(
          _searchError!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.error),
        ),
      );
    }

    if (_searchResults.isEmpty) {
      return EmptyState(
        icon: _hasSearched ? Icons.search_off_rounded : Icons.person_search_rounded,
        title: _hasSearched
            ? 'No users found for "${_searchController.text.trim()}"'
            : 'Find people to chat with',
        subtitle: _hasSearched ? null : 'Enter a username or email to search',
      );
    }

    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      itemCount: _searchResults.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) => _buildUserCard(_searchResults[index]),
    );
  }

  @override
  void dispose() {
    SocketService.socket.off(SocketEvents.profileUpdated, _handleProfileUpdated);
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.groupChatId != null ? 'Add Members' : 'Search')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              onChanged: _scheduleSearch,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search by username or email...',
                prefixIcon: Icon(Icons.search, color: AppColors.primary),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _scheduleSearch('');
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: AppColors.cardBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: AppColors.cardBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: AppColors.primary, width: 1.6),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(child: _buildSearchBody()),
          ],
        ),
      ),
    );
  }
}
