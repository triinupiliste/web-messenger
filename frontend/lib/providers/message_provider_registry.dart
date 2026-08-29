import 'message_provider.dart';

// Keeps one MessageProvider per chatId for the app session instead of
// recreating one each time a chat is opened, so history/scroll state and
// socket subscriptions survive split-pane swaps and reopened chats.
//
// Deliberately never evicted/disposed — acceptable for this app's session length.
class MessageProviderRegistry {
  MessageProviderRegistry._();

  static final Map<String, MessageProvider> _providers = {};

  static MessageProvider getOrCreate(String chatId) {
    final existing = _providers[chatId];
    if (existing != null) {
      // Re-attaches socket listeners if the underlying socket changed (e.g. a
      // different user logged in), so this cached provider isn't left deaf.
      existing.ensureSocketListeners();
      return existing;
    }
    return _providers.putIfAbsent(chatId, () => MessageProvider(chatId)..init());
  }
}
