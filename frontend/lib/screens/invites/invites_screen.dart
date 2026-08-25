import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/invite_provider.dart';
import '../../theme/app_colors.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/common/empty_state.dart';
import '../../widgets/common/user_avatar.dart';

class InvitesScreen extends StatefulWidget {
  // When true, marks incoming invites as seen as soon as this screen loads,
  // instead of relying on the bottom-nav tap handler.
  final bool markSeenOnOpen;

  const InvitesScreen({super.key, this.markSeenOnOpen = false});

  @override
  State<InvitesScreen> createState() => InvitesScreenState();
}

class InvitesScreenState extends State<InvitesScreen> {
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await context.read<InviteProvider>().fetchInvites();
    if (widget.markSeenOnOpen && mounted) {
      context.read<InviteProvider>().markIncomingSeen();
    }
  }

  Future<void> refresh() => context.read<InviteProvider>().fetchInvites();

  Future<void> _respond(String inviteId, String status) async {
    try {
      await context.read<InviteProvider>().respondToInvite(inviteId, status);
      if (status == 'accepted' && mounted) {
        // A new chat was created on the backend; refresh the chat list so it appears immediately.
        context.read<ChatProvider>().fetchChats();
      }
      if (mounted) {
        SnackBarHelper.show(context, 'Invitation $status successfully!');
      }
    } catch (e) {
      if (mounted) {
        SnackBarHelper.show(context, 'Error: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final inviteProvider = context.watch<InviteProvider>();
    final incoming = inviteProvider.incoming;
    final outgoing = inviteProvider.outgoing;
    final isLoading = inviteProvider.isLoading && incoming.isEmpty && outgoing.isEmpty;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.primary,
          title: const Text('Chat Invitations',
              style: TextStyle(color: Colors.white)),
          iconTheme: const IconThemeData(color: Colors.white),
          bottom: const TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white60,
            indicatorColor: Colors.white,
            indicatorWeight: 3,
            tabs: [
              Tab(text: 'Incoming'),
              Tab(text: 'Outgoing'),
            ],
          ),
        ),
        body: isLoading
            ? Center(
                child: CircularProgressIndicator(color: AppColors.primary))
            : TabBarView(
                children: [
                  incoming.isEmpty
                      ? const EmptyState(
                          icon: Icons.mail_outline_rounded,
                          title: 'No incoming invitations',
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: incoming.length,
                          itemBuilder: (context, index) {
                            final invite = incoming[index];
                            final sender = invite['sender'] ?? {};
                            final senderAvatar = sender['avatar_url']?.toString();
                            final group = invite['group'];
                            final isGroupInvite = group != null;
                            final groupName = group?['name']?.toString() ?? 'a group';
                            return Card(
                              color: AppColors.surface,
                              margin: const EdgeInsets.symmetric(vertical: 6),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(color: AppColors.primary.withValues(alpha: 0.25)),
                              ),
                              child: ListTile(
                                leading: isGroupInvite
                                    ? CircleAvatar(
                                        backgroundColor: AppColors.primary.withValues(alpha: 0.15),
                                        child: Icon(Icons.groups_rounded, color: AppColors.primary),
                                      )
                                    : UserAvatar(
                                        avatarUrl: senderAvatar,
                                        displayName: sender['username']?.toString() ?? '',
                                      ),
                                title: Text(
                                    isGroupInvite ? groupName : (sender['username'] ?? 'User'),
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.textPrimary)),
                                subtitle: Text(
                                    isGroupInvite
                                        ? '${sender['username'] ?? 'Someone'} invited you to join this group'
                                        : (sender['email'] ?? ''),
                                    style: TextStyle(
                                        color: AppColors.textSecondary)),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.check,
                                          color: Colors.green),
                                      onPressed: () => _respond(
                                          invite['id'] ?? invite['_id'],
                                          'accepted'),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.close,
                                          color: AppColors.error),
                                      onPressed: () => _respond(
                                          invite['id'] ?? invite['_id'],
                                          'declined'),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                  outgoing.isEmpty
                      ? const EmptyState(
                          icon: Icons.send_outlined,
                          title: 'No outgoing invitations',
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: outgoing.length,
                          itemBuilder: (context, index) {
                            final invite = outgoing[index];
                            final recipient = invite['recipient'] ?? {};
                            final recipientAvatar = recipient['avatar_url']?.toString();
                            final group = invite['group'];
                            final isGroupInvite = group != null;
                            final groupName = group?['name']?.toString() ?? 'a group';
                            return Card(
                              color: AppColors.surface,
                              margin: const EdgeInsets.symmetric(vertical: 6),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(color: AppColors.primary.withValues(alpha: 0.25)),
                              ),
                              child: ListTile(
                                leading: UserAvatar(
                                  avatarUrl: recipientAvatar,
                                  displayName: recipient['username']?.toString() ?? '',
                                ),
                                title: Text(recipient['username'] ?? 'User',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.textPrimary)),
                                subtitle: Text(
                                    isGroupInvite
                                        ? 'Invited to join "$groupName"'
                                        : (recipient['email'] ?? ''),
                                    style: TextStyle(
                                        color: AppColors.textSecondary)),
                                trailing: Chip(
                                  label: Text(
                                      (invite['status'] ?? 'Pending')
                                          .toString(),
                                      style: TextStyle(
                                          fontSize: 12, color: Colors.white)),
                                  backgroundColor: AppColors.secondary,
                                ),
                              ),
                            );
                          },
                        ),
                ],
              ),
      ),
    );
  }
}
