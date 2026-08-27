// Facade: picks the interactive native crop UI on mobile (image_cropper) or
// an automatic centered-square crop via HTML canvas on web, at compile time.
// See avatar_cropper_web.dart for why web doesn't use image_cropper's own
// (currently broken) web crop dialog.
export 'avatar_cropper_mobile.dart' if (dart.library.html) 'avatar_cropper_web.dart';
