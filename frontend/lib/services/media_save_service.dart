// Facade: picks the gallery-save implementation on mobile/desktop (uses the
// `gal` package, which has no web support) or the browser-download
// implementation on web, at compile time — callers just do
// `MediaSaveService.saveNetworkMedia(...)` and get the right behavior for
// whichever platform they're compiled for.
export 'media_save_service_mobile.dart'
    if (dart.library.html) 'media_save_service_web.dart';
