import 'dart:typed_data';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'api_service.dart';

/// Generates a first-frame thumbnail for a video message and caches the
/// result in memory, keyed by URL, so re-rendering a bubble (e.g. after it
/// scrolls back into view) doesn't re-download/re-decode the video.
class VideoThumbnailService {
  static final Map<String, Uint8List?> _cache = {};

  static Future<Uint8List?> getThumbnail(String url) async {
    if (_cache.containsKey(url)) {
      return _cache[url];
    }

    try {
      final bytes = await VideoThumbnail.thumbnailData(
        video: ApiService.mediaUrl(url),
        // ngrok returns its HTML interstitial warning page instead of video bytes without this.
        headers: ApiService.ngrokHeader,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 400,
        quality: 60,
      );
      _cache[url] = bytes;
      return bytes;
    } catch (_) {
      _cache[url] = null;
      return null;
    }
  }
}
