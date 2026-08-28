import 'message_provider.dart';

// Keeps one MessageProvider per chatId for the lifetime of the app session,
// instead of constructing a new one each time a chat is opened. This lets the
// split-pane layout swap the detail pane between chats without losing
// history/scroll state, and lets reopened chats reuse cached messages/socket
// subscriptions instead of refetching.
//
// Deliberately no eviction/dispose for chats navigated away from — keeping
// them alive for the whole session is an acceptable tradeoff here.
class MessageProviderRegistry {
  MessageProviderRegistry._();

  static final Map<String, MessageProvider> _providers = {};

  static MessageProvider getOrCreate(String chatId) {
    final existing = _providers[chatId];
    if (existing != null) {
      // Re-attaches socket listeners/room membership if the socket changed
      // since last attached (e.g. a different user logged in), otherwise this
      // cached provider would be silently deaf to real-time updates.
      existing.ensureSocketListeners();
      return existing;
    }
    return _providers.putIfAbsent(chatId, () => MessageProvider(chatId)..init());
  }
}
