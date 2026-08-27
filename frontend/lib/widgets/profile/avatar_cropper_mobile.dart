import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import '../../theme/app_colors.dart';

// Mobile implementation: image_cropper's native Android crop screen (uCrop)
// is mature and reliable, unlike its web counterpart (see avatar_cropper_web.dart).
Future<Uint8List?> cropAvatarImage(BuildContext context, String sourcePath) async {
  final croppedFile = await ImageCropper().cropImage(
    sourcePath: sourcePath,
    aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
    uiSettings: [
      AndroidUiSettings(
        toolbarTitle: 'Crop Profile Picture',
        toolbarColor: AppColors.primary,
        toolbarWidgetColor: Colors.white,
        initAspectRatio: CropAspectRatioPreset.square,
        lockAspectRatio: true,
      ),
    ],
  );

  if (croppedFile == null) return null;

  // readAsBytes() works cross-platform (unlike dart:io File, which can't
  // read the blob: URLs image_picker/image_cropper hand back on web).
  return croppedFile.readAsBytes();
}
