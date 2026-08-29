import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;
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
    } catch (e) {
      debugPrint('Error generating video thumbnail on web: $e');
      bytes = null;
    }
    _cache[url] = bytes;
    return bytes;
  }

  static Future<Uint8List?> _captureFrame(String videoUrl) async {
    final response = await http.get(Uri.parse(videoUrl), headers: ApiService.ngrokHeader);
    if (response.statusCode != 200) return null;

    final blob = web.Blob([response.bodyBytes.toJS].toJS);
    final objectUrl = web.URL.createObjectURL(blob);
    try {
      return await _grabFrame(objectUrl);
    } finally {
      web.URL.revokeObjectURL(objectUrl);
    }
  }

  static Future<Uint8List?> _grabFrame(String objectUrl) {
    final completer = Completer<Uint8List?>();
    final video = web.HTMLVideoElement()
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

    video.onerror = ((JSAny? _) => finish(null)).toJS;
    video.onloadeddata = (JSAny? _) {
      // Avoids some codecs returning a blank first frame at t=0.
      video.currentTime = 0.1;
    }.toJS;
    video.onseeked = (JSAny? _) {
      _captureCanvasFrame(video).then(finish).catchError((Object e) {
        debugPrint('Error capturing video frame on web: $e');
        finish(null);
      });
    }.toJS;

    web.document.body?.append(video);
    // Guards against a video that never fires loadeddata/seeked.
    Future.delayed(const Duration(seconds: 5), () => finish(null));
    return completer.future;
  }

  static Future<Uint8List?> _captureCanvasFrame(web.HTMLVideoElement video) async {
    final canvas = web.HTMLCanvasElement()
      ..width = video.videoWidth
      ..height = video.videoHeight;
    final context = canvas.getContext('2d') as web.CanvasRenderingContext2D;
    context.drawImage(video, 0, 0);

    final blobCompleter = Completer<web.Blob?>();
    canvas.toBlob(
      ((web.Blob? result) => blobCompleter.complete(result)).toJS,
      'image/jpeg',
      0.7.toJS,
    );
    final blob = await blobCompleter.future;
    if (blob == null) return null;

    final readCompleter = Completer<void>();
    final reader = web.FileReader()
      ..onloadend = ((JSAny? _) => readCompleter.complete()).toJS
      ..readAsArrayBuffer(blob);
    await readCompleter.future;
    return (reader.result as JSArrayBuffer).toDart.asUint8List();
  }
}
