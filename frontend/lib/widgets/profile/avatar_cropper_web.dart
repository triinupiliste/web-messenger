import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'dart:typed_data';
import 'package:flutter/material.dart';

// Web implementation. image_cropper's web crop UI has multiple unresolved
// upstream bugs (blank dialog, unselectable crop handles — see
// hnvn/flutter_image_cropper issues #615, #616, #621), so instead of a broken
// manual crop UI, this auto-crops the image to a centered square and
// re-encodes it as JPEG via an offscreen <canvas>.
Future<Uint8List?> cropAvatarImage(BuildContext context, String sourcePath) async {
  final image = web.HTMLImageElement();
  final loaded = Completer<void>();
  image.onload = ((JSAny? _) {
    if (!loaded.isCompleted) loaded.complete();
  }).toJS;
  image.onerror = ((JSAny? _) {
    if (!loaded.isCompleted) loaded.completeError('Failed to load picked image.');
  }).toJS;
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
  final canvas = web.HTMLCanvasElement()
    ..width = outputSize
    ..height = outputSize;
  final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
  ctx.drawImage(
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

  final dataUrl = canvas.toDataURL('image/jpeg', 0.9.toJS);
  final base64Data = dataUrl.substring(dataUrl.indexOf(',') + 1);
  return base64Decode(base64Data);
}
