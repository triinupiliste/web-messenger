import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/invite_provider.dart';
import '../../theme/app_colors.dart';
import '../chat/chat_list_screen.dart';
import '../chat/chat_room_screen.dart';
import '../invites/invites_screen.dart';
import '../search/search_screen.dart';
import '../profile/profile_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  // Lets screens pushed on top of HomeScreen (e.g. ChatRoomScreen) switch back to a
  // specific tab once popped, regardless of which tab was active before navigating away.
  static final GlobalKey<HomeScreenState> homeKey = GlobalKey<HomeScreenState>();

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  static const _chatsTabIndex = 0;
  static const _invitesTabIndex = 1;
  static const _profileTabIndex = 3;

  // Below this width the app keeps its original mobile bottom-nav layout;
  // at/above it, a side NavigationRail is used instead (better use of space
  // on web/desktop/tablet, and the first step towards a wide-screen,
  // multi-pane layout).
  static const double _wideLayoutBreakpoint = 760;

  int _currentIndex = 0;
  final _profileKey = GlobalKey<ProfileScreenState>();

  // Wide-screen split-pane (Chats tab only): which chat is shown in the
  // detail pane alongside the chat list. Null means nothing selected yet
  // (shows a placeholder). Lives here (not in ChatListScreen) so it survives
  // switching to another tab and back.
  String? _selectedChatId;
  String _selectedContactId = '';
  String _selectedContactName = '';
  bool _selectedIsGroup = false;

  void _selectChat(String chatId, String contactId, String contactName, bool isGroup) {
    setState(() {
      _selectedChatId = chatId;
      _selectedContactId = contactId;
      _selectedContactName = contactName;
      _selectedIsGroup = isGroup;
    });
  }

  void _clearSelectedChat() {
    if (_selectedChatId == null) return;
    setState(() => _selectedChatId = null);
  }

  // Switches to the Chats tab and refreshes it, mirroring what tapping the
  // Chats tab itself does. Used by ChatRoomScreen after removing a friend.
  void switchToChatsTab() {
    if (_currentIndex != _chatsTabIndex) {
      setState(() => _currentIndex = _chatsTabIndex);
    }
    context.read<ChatProvider>().fetchChats();
  }

  // A getter (not a field) so it builds fresh widget instances each time: IndexedStack
  // skips rebuilding a child if the exact same widget instance is passed again, which
  // would stop background tabs from picking up theme changes from RestartWidget.
  // `const` is deliberately omitted for the same reason.
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
  // a fixed-width left column while the selected chat opens directly in the
  // remaining space, instead of navigating away to a full-screen route.
  Widget _buildChatsSplitPane() {
    return Row(
      children: [
        SizedBox(
          width: 360,
          child: ChatListScreen(
            splitPaneMode: true,
            selectedChatId: _selectedChatId,
            onChatSelected: _selectChat,
          ),
        ),
        const VerticalDivider(width: 1, thickness: 1),
        Expanded(
          child: _selectedChatId == null
              ? _buildNoChatSelectedPlaceholder()
              : ChatRoomScreen(
                  // Forces a full remount (dispose + initState) when the
                  // selection changes, since chatId/contactName aren't the
                  // only state this screen owns (search box, group member
                  // cache, etc.) — without this key Flutter would just patch
                  // the existing element's widget config in place.
                  key: ValueKey(_selectedChatId),
                  chatId: _selectedChatId!,
                  contactId: _selectedContactId,
                  contactName: _selectedContactName,
                  isGroup: _selectedIsGroup,
                  onClose: _clearSelectedChat,
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


