// Facade: picks the native-decoder thumbnail implementation on mobile/desktop
// or the <video>+<canvas> capture implementation on web, at compile time —
// callers just do `VideoThumbnailService.getThumbnail(url)` and get the right
// behavior for whichever platform they're compiled for.
export 'video_thumbnail_service_mobile.dart'
    if (dart.library.html) 'video_thumbnail_service_web.dart';
