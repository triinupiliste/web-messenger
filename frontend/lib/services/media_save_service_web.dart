import 'dart:html' as html;
import 'package:http/http.dart' as http;
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
      // <a download> only forces a save (rather than navigating the tab away)
      // for same-origin URLs, not guaranteed since the backend can be hosted
      // separately. Fetching the bytes into a blob: URL sidesteps that, since
      // blob URLs are always same-origin.
      final response = await http.get(Uri.parse(ApiService.mediaUrl(url)));
      if (response.statusCode != 200) return MediaSaveResult.failed;

      final blob = html.Blob([response.bodyBytes]);
      final objectUrl = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: objectUrl)
        ..download = _fileNameFor(url, mediaType)
        ..style.display = 'none';
      html.document.body?.append(anchor);
      anchor.click();
      anchor.remove();
      html.Url.revokeObjectUrl(objectUrl);
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
