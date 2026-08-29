import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../constants/socket_events.dart';
import '../../providers/chat_provider.dart';
import '../../providers/invite_provider.dart';
import '../../services/socket_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/snackbar_helper.dart';
import '../chat/chat_list_screen.dart';
import '../chat/chat_room_screen.dart';
import '../invites/invites_screen.dart';
import '../search/search_screen.dart';
import '../profile/profile_screen.dart';

// One chat currently shown in its own pane in the split-pane layout. On web
// several can be open side by side; on mobile there's never more than one.
class _OpenChat {
  final String chatId;
  final String contactId;
  final String contactName;
  final bool isGroup;

  const _OpenChat({
    required this.chatId,
    required this.contactId,
    required this.contactName,
    required this.isGroup,
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  // Lets screens pushed on top of HomeScreen (e.g. ChatRoomScreen) switch back
  // to a specific tab once popped.
  static final GlobalKey<HomeScreenState> homeKey = GlobalKey<HomeScreenState>();

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  static const _chatsTabIndex = 0;
  static const _invitesTabIndex = 1;
  static const _profileTabIndex = 3;

  // Below this width the app keeps the mobile bottom-nav layout; at/above it,
  // a side NavigationRail is used instead.
  static const double _wideLayoutBreakpoint = 760;

  int _currentIndex = 0;
  final _profileKey = GlobalKey<ProfileScreenState>();

  // Wide-screen split-pane (Chats tab only): chat(s) shown in the detail
  // pane(s). Lives here so it survives switching tabs and back. Web allows
  // multiple side-by-side panes (mobile only ever holds one); _maxPanesFor()
  // further limits the actual pane count.
  static const _maxOpenChatsOnWeb = 3;

  // Below this width a chat pane's app bar and composer row start clipping,
  // so a new pane is never opened unless it would have at least this much room.
  static const _minChatPaneWidth = 420.0;

  // Chat list column width + its divider, subtracted from the total width
  // before figuring out how many chat panes fit in what's left.
  static const _chatListColumnWidth = 361.0;

  final List<_OpenChat> _openChats = [];

  late final void Function(dynamic) _onGroupMemberRemoved;

  @override
  void initState() {
    super.initState();
    // Notifies the user if a group owner removes them from anywhere in the
    // app, not just while that chat room happens to be open.
    _onGroupMemberRemoved = (data) {
      if (!mounted) return;
      if (data['removedBySelf'] == true) return;
      final myUserId = context.read<ChatProvider>().currentUserId;
      if (myUserId == null || data['userId']?.toString() != myUserId) return;
      final chatName = data['chatName']?.toString();
      SnackBarHelper.show(
        context,
        chatName != null && chatName.isNotEmpty
            ? 'You were removed from "$chatName".'
            : 'You were removed from a group.',
      );
    };
    SocketService.on(SocketEvents.groupMemberRemoved, _onGroupMemberRemoved);
  }

  @override
  void dispose() {
    SocketService.off(SocketEvents.groupMemberRemoved, _onGroupMemberRemoved);
    super.dispose();
  }

  // How many chat panes fit side by side in the given width, capped by
  // _maxOpenChatsOnWeb and always at least 1.
  int _maxPanesFor(double totalWidth) {
    final availableForPanes = totalWidth - _chatListColumnWidth;
    final panes = (availableForPanes / _minChatPaneWidth).floor();
    return panes.clamp(1, _maxOpenChatsOnWeb);
  }

  void _selectChat(String chatId, String contactId, String contactName, bool isGroup) {
    setState(() {
      if (_openChats.any((c) => c.chatId == chatId)) return; // already open in its own pane

      final newChat = _OpenChat(
        chatId: chatId,
        contactId: contactId,
        contactName: contactName,
        isGroup: isGroup,
      );

      if (!kIsWeb) {
        _openChats
          ..clear()
          ..add(newChat);
        return;
      }

      // Web: keep adding side-by-side panes, evicting the oldest once as many
      // panes as currently fit are already open, so panes don't get squeezed
      // down to unreadable/overlapping widths.
      final maxPanes = _maxPanesFor(MediaQuery.sizeOf(context).width);
      while (_openChats.length >= maxPanes) {
        _openChats.removeAt(0);
      }
      _openChats.add(newChat);
    });
  }

  void _closeChat(String chatId) {
    setState(() => _openChats.removeWhere((c) => c.chatId == chatId));
  }

  // Switches to the Chats tab and refreshes it, mirroring what tapping the
  // Chats tab itself does. Used by ChatRoomScreen after removing a friend.
  void switchToChatsTab() {
    if (_currentIndex != _chatsTabIndex) {
      setState(() => _currentIndex = _chatsTabIndex);
    }
    context.read<ChatProvider>().fetchChats();
  }

  // Opens a chat from outside the Chats tab (e.g. "Send Message" on a search
  // result), switching to the Chats tab first so it doesn't look like an
  // overlay. Opens side by side on the wide split-pane layout, or as a pushed
  // route on narrow layouts.
  void openChat(String chatId, String contactId, String contactName, bool isGroup) {
    switchToChatsTab();
    final isWide = MediaQuery.sizeOf(context).width >= _wideLayoutBreakpoint;
    if (isWide) {
      _selectChat(chatId, contactId, contactName, isGroup);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(
          chatId: chatId,
          contactId: contactId,
          contactName: contactName,
          isGroup: isGroup,
        ),
      ),
    );
  }

  // A getter (not a field) so IndexedStack always gets fresh widget instances
  // — otherwise it skips rebuilding a child, which would stop background tabs
  // from picking up theme changes from RestartWidget.
  List<Widget> get _screens => [
    ChatListScreen(),
    InvitesScreen(),
    SearchScreen(onInviteSent: () => context.read<InviteProvider>().fetchInvites()),
    ProfileScreen(key: _profileKey),
  ];

  // Shared by both the bottom NavigationBar (narrow) and the side
  // NavigationRail (wide) layouts, so tab-switching behaves identically
  // regardless of which one is currently shown.
  Future<void> _onDestinationSelected(int index) async {
    if (index == _currentIndex) return;

    // Capture providers *before* any async gaps to avoid context warnings
    final chatProvider = context.read<ChatProvider>();
    final inviteProvider = context.read<InviteProvider>();

    if (_currentIndex == _profileTabIndex) {
      final canLeave =
          await _profileKey.currentState?.confirmDiscardChangesIfNeeded() ?? true;
      if (!canLeave) return;
    }

    if (!mounted) return;

    setState(() {
      _currentIndex = index;
    });

    if (index == 0) {
      await chatProvider.fetchChats();
    } else if (index == _invitesTabIndex) {
      await inviteProvider.fetchInvites();

      if (!mounted) return;
      inviteProvider.markIncomingSeen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalUnreadMessages = context.watch<ChatProvider>().totalUnreadCount;
    final unseenInvites = context.watch<InviteProvider>().unseenCount;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= _wideLayoutBreakpoint;
        final showChatsSplitPane = isWide && _currentIndex == _chatsTabIndex;

        // If the window shrank enough that not all currently open panes fit
        // anymore, trim the oldest ones down to what actually fits. Deferred
        // to after this frame since it's not safe to call setState mid-build.
        if (showChatsSplitPane) {
          final maxPanes = _maxPanesFor(constraints.maxWidth);
          if (_openChats.length > maxPanes) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() {
                while (_openChats.length > maxPanes) {
                  _openChats.removeAt(0);
                }
              });
            });
          }
        }

        return Scaffold(
          body: Row(
            children: [
              if (isWide) ...[
                _buildNavigationRail(totalUnreadMessages, unseenInvites),
                const VerticalDivider(width: 1, thickness: 1),
              ],
              Expanded(
                child: showChatsSplitPane
                    ? _buildChatsSplitPane()
                    : IndexedStack(index: _currentIndex, children: _screens),
              ),
            ],
          ),
          bottomNavigationBar: isWide
              ? null
              : _buildBottomNavigationBar(totalUnreadMessages, unseenInvites),
        );
      },
    );
  }


  // Wide-screen-only layout for the Chats tab: the chat list stays visible in
  // a fixed-width column while selected chat(s) open as side-by-side panes,
  // instead of navigating to a full-screen route.
  Widget _buildChatsSplitPane() {
    return Row(
      children: [
        SizedBox(
          width: 360,
          child: ChatListScreen(
            splitPaneMode: true,
            openChatIds: _openChats.map((c) => c.chatId).toSet(),
            onChatSelected: _selectChat,
          ),
        ),
        const VerticalDivider(width: 1, thickness: 1),
        Expanded(
          child: _openChats.isEmpty
              ? _buildNoChatSelectedPlaceholder()
              : Row(
                  children: [
                    for (var i = 0; i < _openChats.length; i++) ...[
                      if (i > 0) const VerticalDivider(width: 1, thickness: 1),
                      Expanded(
                        child: ChatRoomScreen(
                          // Forces a full remount when the selection changes, since
                          // this screen owns state beyond chatId/contactName (search
                          // box, member cache, etc.).
                          key: ValueKey(_openChats[i].chatId),
                          chatId: _openChats[i].chatId,
                          contactId: _openChats[i].contactId,
                          contactName: _openChats[i].contactName,
                          isGroup: _openChats[i].isGroup,
                          onClose: () => _closeChat(_openChats[i].chatId),
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildNoChatSelectedPlaceholder() {
    return Container(
      color: AppColors.background,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline_rounded, size: 64, color: AppColors.textSecondary),
          const SizedBox(height: 12),
          Text(
            'Select a chat to start messaging',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationRail(int totalUnreadMessages, int unseenInvites) {
    return NavigationRail(
      selectedIndex: _currentIndex,
      onDestinationSelected: _onDestinationSelected,
      labelType: NavigationRailLabelType.all,
      backgroundColor: AppColors.surface,
      destinations: [
        NavigationRailDestination(
          icon: Badge(
            isLabelVisible: totalUnreadMessages > 0,
            label: Text(totalUnreadMessages > 99 ? '99+' : '$totalUnreadMessages'),
            child: const Icon(Icons.chat_bubble_outline_rounded),
          ),
          selectedIcon: Badge(
            isLabelVisible: totalUnreadMessages > 0,
            label: Text(totalUnreadMessages > 99 ? '99+' : '$totalUnreadMessages'),
            child: const Icon(Icons.chat_bubble_rounded),
          ),
          label: const Text('Chats'),
        ),
        NavigationRailDestination(
          icon: Badge(
            isLabelVisible: unseenInvites > 0,
            label: Text(unseenInvites > 99 ? '99+' : '$unseenInvites'),
            child: const Icon(Icons.mail_outline_rounded),
          ),
          selectedIcon: Badge(
            isLabelVisible: unseenInvites > 0,
            label: Text(unseenInvites > 99 ? '99+' : '$unseenInvites'),
            child: const Icon(Icons.mail_rounded),
          ),
          label: const Text('Invites'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.search_rounded),
          label: Text('Search'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.person_outline_rounded),
          selectedIcon: Icon(Icons.person_rounded),
          label: Text('Profile'),
        ),
      ],
    );
  }

  Widget _buildBottomNavigationBar(int totalUnreadMessages, int unseenInvites) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        boxShadow: [
          BoxShadow(
            color: AppColors.floatingBarShadow,
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: _onDestinationSelected,
          backgroundColor: AppColors.surface,
          elevation: 0,
          destinations: [
            NavigationDestination(
              icon: Badge(
                isLabelVisible: totalUnreadMessages > 0,
                label: Text(totalUnreadMessages > 99 ? '99+' : '$totalUnreadMessages'),
                child: const Icon(Icons.chat_bubble_outline_rounded),
              ),
              selectedIcon: Badge(
                isLabelVisible: totalUnreadMessages > 0,
                label: Text(totalUnreadMessages > 99 ? '99+' : '$totalUnreadMessages'),
                child: const Icon(Icons.chat_bubble_rounded),
              ),
              label: 'Chats',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: unseenInvites > 0,
                label: Text(unseenInvites > 99 ? '99+' : '$unseenInvites'),
                child: const Icon(Icons.mail_outline_rounded),
              ),
              selectedIcon: Badge(
                isLabelVisible: unseenInvites > 0,
                label: Text(unseenInvites > 99 ? '99+' : '$unseenInvites'),
                child: const Icon(Icons.mail_rounded),
              ),
              label: 'Invites',
            ),
            const NavigationDestination(
              icon: Icon(Icons.search_rounded),
              label: 'Search',
            ),
            const NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}


