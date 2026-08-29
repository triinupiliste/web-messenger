import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'api_service.dart';

/// Generates a first-frame thumbnail for a video message and caches the
/// result in memory, keyed by URL.
///
/// video_thumbnail has no web implementation, so this loads the video into an
/// off-DOM <video> element, seeks to a frame, and captures it via <canvas>.
/// The video is fetched into a blob: URL first so the ngrok header can be
/// attached and the canvas isn't tainted by a cross-origin source.
class VideoThumbnailService {
  static final Map<String, Uint8List?> _cache = {};

  static Future<Uint8List?> getThumbnail(String url) async {
    if (_cache.containsKey(url)) {
      return _cache[url];
    }

    Uint8List? bytes;
    try {
      bytes = await _captureFrame(ApiService.mediaUrl(url));
    } catch (_) {
      bytes = null;
    }
    _cache[url] = bytes;
    return bytes;
  }

  static Future<Uint8List?> _captureFrame(String videoUrl) async {
    final response = await http.get(Uri.parse(videoUrl), headers: ApiService.ngrokHeader);
    if (response.statusCode != 200) return null;

    final blob = html.Blob([response.bodyBytes]);
    final objectUrl = html.Url.createObjectUrlFromBlob(blob);
    try {
      return await _grabFrame(objectUrl);
    } finally {
      html.Url.revokeObjectUrl(objectUrl);
    }
  }

  static Future<Uint8List?> _grabFrame(String objectUrl) {
    final completer = Completer<Uint8List?>();
    final video = html.VideoElement()
      ..src = objectUrl
      ..muted = true
      ..preload = 'auto';

    var settled = false;
    void finish(Uint8List? result) {
      if (settled) return;
      settled = true;
      video.remove();
      if (!completer.isCompleted) completer.complete(result);
    }

    video.onError.listen((_) => finish(null));
    video.onLoadedData.listen((_) {
      // Avoids some codecs returning a blank first frame at t=0.
      video.currentTime = 0.1;
    });
    video.onSeeked.listen((_) async {
      try {
        final canvas = html.CanvasElement(width: video.videoWidth, height: video.videoHeight)
          ..context2D.drawImage(video, 0, 0);
        final blob = await canvas.toBlob('image/jpeg', 0.7);
        final reader = html.FileReader()..readAsArrayBuffer(blob);
        await reader.onLoadEnd.first;
        finish((reader.result as ByteBuffer).asUint8List());
      } catch (_) {
        finish(null);
      }
    });

    html.document.body?.append(video);
    // Guards against a video that never fires loadeddata/seeked.
    Future.delayed(const Duration(seconds: 5), () => finish(null));
    return completer.future;
  }
}
