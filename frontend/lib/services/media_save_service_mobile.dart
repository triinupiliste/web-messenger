import 'dart:io';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'api_service.dart';

/// Result of a save attempt, so the UI can show an appropriate message
/// without this service needing to know about SnackBars/BuildContext.
enum MediaSaveResult { saved, permissionDenied, failed }

/// Downloads a chat photo/video and saves it to the device's gallery.
/// Mobile/desktop implementation (uses gal, no web support) — see
/// media_save_service_web.dart for the web equivalent.
class MediaSaveService {
  static Future<MediaSaveResult> saveNetworkMedia({
    required String url,
    required String mediaType,
  }) async {
    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) return MediaSaveResult.permissionDenied;
      }

      // ngrok serves an HTML interstitial warning page to non-browser requests
      // without this header, which would otherwise get saved as a broken media file.
      final response = await http.get(Uri.parse(ApiService.mediaUrl(url)), headers: ApiService.ngrokHeader);
      if (response.statusCode != 200) return MediaSaveResult.failed;

      final extension = _extensionFor(url, mediaType);
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(
        '${tempDir.path}/${DateTime.now().millisecondsSinceEpoch}.$extension',
      );
      await tempFile.writeAsBytes(response.bodyBytes);

      if (mediaType == 'video') {
        await Gal.putVideo(tempFile.path, album: 'Web & Mobile Messenger');
      } else {
        await Gal.putImage(tempFile.path, album: 'Web & Mobile Messenger');
      }

      await tempFile.delete();
      return MediaSaveResult.saved;
    } on GalException {
      return MediaSaveResult.permissionDenied;
    } catch (_) {
      return MediaSaveResult.failed;
    }
  }

  static String _extensionFor(String url, String mediaType) {
    final pathExtension = url.split('?').first.split('.').last.toLowerCase();
    const knownExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'mp4', 'mov', 'm4v'};
    if (knownExtensions.contains(pathExtension)) return pathExtension;
    return mediaType == 'video' ? 'mp4' : 'jpg';
  }
}
