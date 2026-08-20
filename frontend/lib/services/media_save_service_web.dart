import 'dart:html' as html;
import 'api_service.dart';

/// Result of a save attempt, so the UI can show an appropriate message
/// without this service needing to know about SnackBars/BuildContext.
enum MediaSaveResult { saved, permissionDenied, failed }

/// The web platform has no photo gallery to save into — this triggers a
/// normal browser download instead, which is the closest equivalent UX.
/// There is no permission prompt on web, so [MediaSaveResult.permissionDenied]
/// is never returned here.
class MediaSaveService {
  static Future<MediaSaveResult> saveNetworkMedia({
    required String url,
    required String mediaType,
  }) async {
    try {
      // The `download` attribute only forces a save (rather than navigating/
      // opening a new tab) for same-origin URLs — true for the production
      // deployment (web build served from the same host as the API), but not
      // necessarily for local dev against a separately-hosted backend.
      final anchor = html.AnchorElement(href: ApiService.mediaUrl(url))
        ..download = _fileNameFor(url, mediaType)
        ..style.display = 'none';
      html.document.body?.append(anchor);
      anchor.click();
      anchor.remove();
      return MediaSaveResult.saved;
    } catch (_) {
      return MediaSaveResult.failed;
    }
  }

  static String _fileNameFor(String url, String mediaType) {
    final pathExtension = url.split('?').first.split('.').last.toLowerCase();
    const knownExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'mp4', 'mov', 'm4v'};
    final extension = knownExtensions.contains(pathExtension)
        ? pathExtension
        : (mediaType == 'video' ? 'mp4' : 'jpg');
    return 'mobile-messenger-${DateTime.now().millisecondsSinceEpoch}.$extension';
  }
}
