import 'message_provider.dart';

// Keeps one MessageProvider per chatId for the lifetime of the app session,
// instead of constructing a brand-new one every time a chat is opened. This
// is what lets the wide-screen split-pane layout (Phase 6) swap the detail
// pane between chats without losing history/scroll state, and also means
// reopening a chat you already visited this session (even on mobile) reuses
// its cached messages/socket subscription instead of refetching from scratch.
//
// Deliberately scoped out: no eviction/dispose of providers for chats you've
// navigated away from — for the size of this app, keeping them alive for the
// whole session is an acceptable tradeoff over adding LRU/cleanup logic.
class MessageProviderRegistry {
  MessageProviderRegistry._();

  static final Map<String, MessageProvider> _providers = {};

  static MessageProvider getOrCreate(String chatId) {
    final existing = _providers[chatId];
    if (existing != null) {
      // Re-checks (and if needed, re-attaches) this provider's socket listeners
      // and room membership — a no-op unless the underlying socket has changed
      // since it was last attached (e.g. a different user logged in within this
      // same app session), which would otherwise leave this cached provider
      // silently deaf to real-time updates for this chat.
      existing.ensureSocketListeners();
      return existing;
    }
    return _providers.putIfAbsent(chatId, () => MessageProvider(chatId)..init());
  }
}
