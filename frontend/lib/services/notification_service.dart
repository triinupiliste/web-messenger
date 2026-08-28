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
// notification for one of them can be suppressed while others still notify.
// A set (not a single id) since the split-pane layout can keep more than one
// chat screen mounted at once.
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

// Tracks whether the app is foregrounded. ActiveChatTracker alone isn't
// enough since a chat screen stays mounted while backgrounded.
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
