class NotificationSettingsService {
  static final Map<String, bool> _mutedChats = {};

  static bool isChatMuted(String chatId) {
    return _mutedChats[chatId] ?? false;
  }

  static void toggleMuteChat(String chatId) {
    _mutedChats[chatId] = !isChatMuted(chatId);
  }

  static void setChatMuted(String chatId, bool isMuted) {
    _mutedChats[chatId] = isMuted;
  }
}

// Tracks which chat(s) are currently open on screen, so a foreground push
// notification for one of THEM can be suppressed (its messages are already
// visible live via the socket) while other chats still notify. A set (not a
// single id) is needed since the wide-screen split-pane layout can keep a
// chat's screen mounted alongside the chat list, and a chat could in theory
// be represented by more than one mounted screen at once.
class ActiveChatTracker {
  static final Set<String> _activeChatIds = {};

  static void addActiveChat(String chatId) {
    _activeChatIds.add(chatId);
  }

  static void removeActiveChat(String chatId) {
    _activeChatIds.remove(chatId);
  }

  static bool isChatActive(String chatId) {
    return _activeChatIds.contains(chatId);
  }
}

// Tracks whether the app is currently foregrounded. ActiveChatTracker alone isn't
// enough: a chat screen stays mounted while backgrounded, so anything treating
// "chat is on screen" as "user is looking at it" must check this too.
class AppLifecycleTracker {
  static bool _isForeground = true;

  static bool get isForeground => _isForeground;

  // Notified when the app returns to the foreground, so things that skipped
  // acting while backgrounded (e.g. marking messages read) can catch up.
  static final List<void Function()> _foregroundListeners = [];

  static void addForegroundListener(void Function() listener) {
    _foregroundListeners.add(listener);
  }

  static void removeForegroundListener(void Function() listener) {
    _foregroundListeners.remove(listener);
  }

  static void setForeground(bool value) {
    final wasForeground = _isForeground;
    _isForeground = value;
    if (value && !wasForeground) {
      for (final listener in List<void Function()>.from(_foregroundListeners)) {
        listener();
      }
    }
  }
}
