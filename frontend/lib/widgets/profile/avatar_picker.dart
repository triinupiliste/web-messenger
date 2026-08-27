import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'avatar_cropper.dart';
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

    final bytes = await cropAvatarImage(context, pickedFile.path);
    if (bytes == null) return;

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
      // Named distinctly from the outer `context` on purpose: this one is
      // only valid for popping the sheet itself. It becomes unmounted well
      // before an async image pick + crop can finish, so using it (instead
      // of the outer, longer-lived screen context) for `_pickImage` caused
      // `_pickImage`'s `context.mounted` check to always fail — silently
      // bailing out with no crop dialog and no photo ever applied.
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: Wrap(
            children: <Widget>[
              ListTile(
                leading: Icon(Icons.photo_library, color: AppColors.primary),
                title: const Text('Pick from Gallery'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _pickImage(context, ImageSource.gallery);
                },
              ),
              if (!kIsWeb)
                ListTile(
                  leading: Icon(Icons.photo_camera, color: AppColors.primary),
                  title: const Text('Take a Photo'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
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