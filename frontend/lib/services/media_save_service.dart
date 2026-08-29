// Facade: exports the gallery-save implementation on mobile/desktop (`gal`
// package, no web support) or the browser-download implementation on web, so
// callers just call MediaSaveService.saveNetworkMedia(...) either way.
export 'media_save_service_mobile.dart'
    if (dart.library.html) 'media_save_service_web.dart';
