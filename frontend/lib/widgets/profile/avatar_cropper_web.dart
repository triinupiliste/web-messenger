import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';

// Web implementation. image_cropper's web crop UI embeds a cropperjs
// instance inside a Flutter Dialog via HtmlElementView, which has multiple
// unresolved upstream bugs — the dialog rendering blank/transparent with no
// interactive controls, and crop handles not being selectable at all
// (github.com/hnvn/flutter_image_cropper issues #615, #616, #621). Rather
// than exposing a broken manual crop UI, this auto-crops the picked image to
// a centered square and re-encodes it as JPEG via an offscreen <canvas> —
// the same output shape the interactive cropper would have produced, just
// without requiring (currently broken) manual adjustment on web.
Future<Uint8List?> cropAvatarImage(BuildContext context, String sourcePath) async {
  final image = html.ImageElement();
  final loaded = Completer<void>();
  image.onLoad.first.then((_) {
    if (!loaded.isCompleted) loaded.complete();
  });
  image.onError.first.then((_) {
    if (!loaded.isCompleted) loaded.completeError('Failed to load picked image.');
  });
  image.src = sourcePath;

  try {
    await loaded.future;
  } catch (_) {
    return null;
  }

  final naturalWidth = image.naturalWidth;
  final naturalHeight = image.naturalHeight;
  if (naturalWidth == 0 || naturalHeight == 0) return null;

  final side = naturalWidth < naturalHeight ? naturalWidth : naturalHeight;
  final srcX = (naturalWidth - side) / 2;
  final srcY = (naturalHeight - side) / 2;

  const outputSize = 512;
  final canvas = html.CanvasElement(width: outputSize, height: outputSize);
  final ctx = canvas.context2D;
  ctx.drawImageScaledFromSource(
    image,
    srcX,
    srcY,
    side.toDouble(),
    side.toDouble(),
    0,
    0,
    outputSize.toDouble(),
    outputSize.toDouble(),
  );

  final dataUrl = canvas.toDataUrl('image/jpeg', 0.9);
  final base64Data = dataUrl.substring(dataUrl.indexOf(',') + 1);
  return base64Decode(base64Data);
}
