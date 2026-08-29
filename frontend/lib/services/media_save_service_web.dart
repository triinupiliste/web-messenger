import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;
import 'package:http/http.dart' as http;
import 'api_service.dart';

/// Result of a save attempt, so the UI can show an appropriate message
/// without this service needing to know about SnackBars/BuildContext.
enum MediaSaveResult { saved, permissionDenied, failed }

/// The web platform has no photo gallery — this triggers a normal browser
/// download instead. No permission prompt exists on web, so
/// [MediaSaveResult.permissionDenied] is never returned here.
class MediaSaveService {
  static Future<MediaSaveResult> saveNetworkMedia({
    required String url,
    required String mediaType,
  }) async {
    try {
      // <a download> only forces a save (vs. navigating away) for same-origin
      // URLs, which isn't guaranteed here. Fetching into a blob: URL sidesteps
      // that, since blob URLs are always same-origin.
      final response = await http.get(Uri.parse(ApiService.mediaUrl(url)));
      if (response.statusCode != 200) return MediaSaveResult.failed;

      final blob = web.Blob([response.bodyBytes.toJS].toJS);
      final objectUrl = web.URL.createObjectURL(blob);
      final anchor = web.HTMLAnchorElement()
        ..href = objectUrl
        ..download = _fileNameFor(url, mediaType)
        ..style.display = 'none';
      web.document.body?.append(anchor);
      anchor.click();
      anchor.remove();
      web.URL.revokeObjectURL(objectUrl);
      return MediaSaveResult.saved;
    } catch (e) {
      debugPrint('Error saving media on web: $e');
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
