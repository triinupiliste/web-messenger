import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/chat_provider.dart';
import '../../services/api_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/json_utils.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/common/empty_state.dart';
import '../../widgets/common/user_avatar.dart';
import '../home/home_screen.dart';
import '../search/search_screen.dart';

// Shows a group chat's member list, and (for the owner) lets them rename the
// group or remove members. Any member can add new members or leave the group.
class GroupInfoScreen extends StatefulWidget {
  final String chatId;
  final String groupName;

  const GroupInfoScreen({super.key, required this.chatId, required this.groupName});

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  List<dynamic> _members = [];
  bool _isLoading = true;
  String? _currentUserId;
  late String _groupName;

  bool get _isOwner {
    final me = _members.firstWhere(
      (m) => m['user_id']?.toString() == _currentUserId,
      orElse: () => null,
    );
    return me != null && me['role'] == 'owner';
  }

  @override
  void initState() {
    super.initState();
    _groupName = widget.groupName;
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final profile = await ApiService.getProfile();
      final members = await ApiService.getGroupMembers(widget.chatId);
      if (!mounted) return;
      setState(() {
        _currentUserId = extractUserId(profile);
        _members = members;
      });
    } catch (e) {
      if (mounted) {
        SnackBarHelper.show(context, 'Failed to load group: ${e.toString().replaceFirst('Exception: ', '')}');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _renameGroup() async {
    final controller = TextEditingController(text: _groupName);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Group'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 100,
          decoration: const InputDecoration(hintText: 'Group name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newName == null || newName.isEmpty || newName == _groupName) return;

    try {
      await ApiService.renameGroup(widget.chatId, newName);
      if (!mounted) return;
      setState(() => _groupName = newName);
      context.read<ChatProvider>().fetchChats();
    } catch (e) {
      if (!mounted) return;
      SnackBarHelper.show(context, 'Failed to rename group: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> _addMembers() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SearchScreen(groupChatId: widget.chatId)),
    );
    if (mounted) _load();
  }

  Future<void> _removeMember(String userId, String username) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Member'),
        content: Text('Remove $username from this group?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ApiService.removeGroupMember(widget.chatId, userId);
      if (!mounted) return;
      setState(() => _members = _members.where((m) => m['user_id']?.toString() != userId).toList());
    } catch (e) {
      if (!mounted) return;
      SnackBarHelper.show(context, 'Failed to remove member: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> _leaveGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave Group'),
        content: Text('Leave "$_groupName"? You will need a new invite to rejoin.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final userId = _currentUserId;
      if (userId == null) return;
      await ApiService.removeGroupMember(widget.chatId, userId);
      if (!mounted) return;
      Navigator.popUntil(context, (route) => route.isFirst);
      HomeScreen.homeKey.currentState?.switchToChatsTab();
      context.read<ChatProvider>().fetchChats();
    } catch (e) {
      if (!mounted) return;
      SnackBarHelper.show(context, 'Failed to leave group: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Group Info'),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 40,
                        backgroundColor: AppColors.primary.withValues(alpha: 0.15),
                        child: Icon(Icons.groups_rounded, size: 40, color: AppColors.primary),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _groupName,
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                          ),
                          if (_isOwner)
                            IconButton(
                              icon: Icon(Icons.edit, size: 18, color: AppColors.primary),
                              onPressed: _renameGroup,
                            ),
                        ],
                      ),
                      Text(
                        '${_members.length} member${_members.length == 1 ? '' : 's'}',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _addMembers,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Add Members'),
                ),
                const SizedBox(height: 16),
                Text('Members', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                const SizedBox(height: 8),
                if (_members.isEmpty)
                  const EmptyState(icon: Icons.groups_outlined, title: 'No members')
                else
                  ..._members.map((m) {
                    final userId = (m['user_id'] ?? '').toString();
                    final username = (m['username'] ?? 'User').toString();
                    final isSelf = userId == _currentUserId;
                    final isMemberOwner = m['role'] == 'owner';
                    return Card(
                      color: AppColors.surface,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        leading: UserAvatar(avatarUrl: m['avatar_url'], displayName: username),
                        title: Text(isSelf ? '$username (You)' : username),
                        subtitle: isMemberOwner ? const Text('Owner') : null,
                        trailing: (_isOwner && !isSelf && !isMemberOwner)
                            ? IconButton(
                                icon: const Icon(Icons.remove_circle_outline, color: AppColors.error),
                                onPressed: () => _removeMember(userId, username),
                              )
                            : null,
                      ),
                    );
                  }),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: _leaveGroup,
                  icon: const Icon(Icons.exit_to_app),
                  label: const Text('Leave Group'),
                ),
              ],
            ),
    );
  }
}
