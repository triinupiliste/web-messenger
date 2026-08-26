import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import '../../theme/app_colors.dart';
import '../../utils/snackbar_helper.dart';
import '../common/user_avatar.dart';

class AvatarPicker extends StatelessWidget {
  final String? currentImageUrl;
  final Uint8List? selectedImageBytes;
  final String displayName;
  final Function(Uint8List) onImageSelected;

  const AvatarPicker({
    super.key,
    this.currentImageUrl,
    this.selectedImageBytes,
    required this.displayName,
    required this.onImageSelected,
  });

  Future<void> _pickImage(BuildContext context, ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: source, imageQuality: 90);

    if (pickedFile == null) return;

    if (!context.mounted) return;

    final croppedFile = await ImageCropper().cropImage(
      sourcePath: pickedFile.path,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop Profile Picture',
          toolbarColor: AppColors.primary,
          toolbarWidgetColor: Colors.white,
          initAspectRatio: CropAspectRatioPreset.square,
          lockAspectRatio: true,
        ),
        // Without this, image_cropper's web plugin has no crop UI to show at
        // all: cropImage() silently resolves to null on web, which is why
        // picking a photo on the web build previously did nothing past the
        // file picker (no crop dialog, and no image ever got applied).
        WebUiSettings(
          context: context,
          presentStyle: WebPresentStyle.dialog,
          size: const CropperSize(width: 400, height: 400),
        ),
      ],
    );

    if (croppedFile == null) return;

    // readAsBytes() works cross-platform (unlike dart:io File, which can't
    // read the blob: URLs that image_picker/image_cropper hand back on web).
    final bytes = await croppedFile.readAsBytes();

    const maxBytes = 5 * 1024 * 1024;
    if (bytes.length > maxBytes) {
      if (context.mounted) {
        SnackBarHelper.show(context, 'Profile pictures must be 5MB or smaller.');
      }
      return;
    }

    onImageSelected(bytes);
  }

  void _showPickerOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: Wrap(
            children: <Widget>[
              ListTile(
                leading: Icon(Icons.photo_library, color: AppColors.primary),
                title: const Text('Pick from Gallery'),
                onTap: () {
                  Navigator.of(context).pop();
                  _pickImage(context, ImageSource.gallery);
                },
              ),
              ListTile(
                leading: Icon(Icons.photo_camera, color: AppColors.primary),
                title: const Text('Take a Photo'),
                onTap: () {
                  Navigator.of(context).pop();
                  _pickImage(context, ImageSource.camera);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget avatar = selectedImageBytes != null
        ? CircleAvatar(
            radius: 50,
            backgroundColor: AppColors.primary.withValues(alpha: 0.1),
            backgroundImage: MemoryImage(selectedImageBytes!),
          )
        : UserAvatar(
            avatarUrl: currentImageUrl,
            displayName: displayName,
            radius: 50,
          );

    return GestureDetector(
      onTap: () => _showPickerOptions(context),
      child: Stack(
        children: [
          avatar,
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.camera_alt, color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}