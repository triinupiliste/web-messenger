// Facade: picks the native-decoder implementation on mobile/desktop or the
// <video>+<canvas> capture implementation on web, at compile time — callers
// just call VideoThumbnailService.getThumbnail(url).
export 'video_thumbnail_service_mobile.dart'
    if (dart.library.html) 'video_thumbnail_service_web.dart';
