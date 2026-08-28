import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../constants/socket_events.dart';
import '../../services/api_service.dart';
import '../../services/socket_service.dart';
import '../../providers/auth_provider.dart';
import '../../theme/app_colors.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/common/user_avatar.dart';
import '../../widgets/profile/avatar_picker.dart';
import '../settings/settings_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => ProfileScreenState();
}

class ProfileScreenState extends State<ProfileScreen> {
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _aboutMeController = TextEditingController();
  String? _avatarUrl;
  Uint8List? _selectedAvatarBytes;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isEditing = false;

  // Snapshot taken when edit mode is entered, so we can tell whether anything
  // actually changed and revert cleanly if the user discards their edits.
  String _usernameAtEditStart = '';
  String _emailAtEditStart = '';
  String _aboutMeAtEditStart = '';
  String? _myUserId;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    // Lets this same account's other active sessions (e.g. editing on the
    // browser while the phone app is open) live-update without a restart.
    SocketService.on(SocketEvents.profileUpdated, _onProfileUpdated);
  }

  void _onProfileUpdated(dynamic data) {
    if (!mounted || _isEditing) return;
    if (_myUserId == null || data['userId']?.toString() != _myUserId) return;
    setState(() {
      if (data['username'] != null) _usernameController.text = data['username'].toString();
      if (data['avatar_url'] != null) _avatarUrl = data['avatar_url'].toString();
      if (data['about_me'] != null) _aboutMeController.text = data['about_me'].toString();
    });
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await ApiService.getProfile();
      setState(() {
        _myUserId = profile['id']?.toString();
        _usernameController.text = profile['username'] ?? '';
        _emailController.text = profile['email'] ?? '';
        _aboutMeController.text = profile['about_me'] ?? '';
        _avatarUrl = profile['avatar_url'];
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        SnackBarHelper.show(context, 'Failed to load profile data.');
      }
    }
  }

  void _enterEditMode() {
    setState(() {
      _isEditing = true;
      _selectedAvatarBytes = null;
      _usernameAtEditStart = _usernameController.text;
      _emailAtEditStart = _emailController.text;
      _aboutMeAtEditStart = _aboutMeController.text;
    });
  }

  bool get _hasUnsavedChanges =>
      _selectedAvatarBytes != null ||
      _usernameController.text != _usernameAtEditStart ||
      _emailController.text != _emailAtEditStart ||
      _aboutMeController.text != _aboutMeAtEditStart;

  Future<void> _handleClosePressed() async {
    await confirmDiscardChangesIfNeeded();
  }

  /// Checks whether it's safe to navigate away from this screen right now.
  /// Returns true if not editing, or no unsaved changes; otherwise prompts to
  /// save/discard and returns false only if the user cancels.
  Future<bool> confirmDiscardChangesIfNeeded() async {
    if (!_isEditing) return true;

    if (!_hasUnsavedChanges) {
      setState(() => _isEditing = false);
      return true;
    }

    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save changes?'),
        content: const Text('You have unsaved changes. Do you want to save them before leaving?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('Discard', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (!mounted || choice == null || choice == 'cancel') return false;

    if (choice == 'discard') {
      setState(() {
        _selectedAvatarBytes = null;
        _usernameController.text = _usernameAtEditStart;
        _emailController.text = _emailAtEditStart;
        _aboutMeController.text = _aboutMeAtEditStart;
        _isEditing = false;
      });
      return true;
    }

    return _saveProfile();
  }

  Future<bool> _saveProfile() async {
    setState(() => _isSaving = true);
    try {
      String? avatarUrlToSave = _avatarUrl;
      if (_selectedAvatarBytes != null) {
        avatarUrlToSave = await ApiService.uploadAvatar(_selectedAvatarBytes!);
      }

      final updated = await ApiService.updateProfile(
        username: _usernameController.text.trim(),
        email: _emailController.text.trim(),
        avatarUrl: avatarUrlToSave,
        aboutMe: _aboutMeController.text.trim(),
      );

      if (!mounted) return true;
      setState(() {
        _usernameController.text = updated['username'] ?? _usernameController.text;
        _emailController.text = updated['email'] ?? _emailController.text;
        _avatarUrl = updated['avatar_url'] ?? avatarUrlToSave;
        _aboutMeController.text = updated['about_me'] ?? _aboutMeController.text;
        _selectedAvatarBytes = null;
        _isEditing = false;
      });
      SnackBarHelper.show(context, 'Profile updated successfully!');
      return true;
    } catch (e) {
      if (mounted) {
        SnackBarHelper.show(context, e.toString().replaceFirst('Exception: ', ''));
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  void dispose() {
    SocketService.off(SocketEvents.profileUpdated, _onProfileUpdated);
    _usernameController.dispose();
    _emailController.dispose();
    _aboutMeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
          body: Center(
              child: CircularProgressIndicator(color: AppColors.primary)));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Profile' : 'My Profile'),
        actions: [
          if (_isEditing)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Close',
              onPressed: _isSaving ? null : _handleClosePressed,
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Edit Profile',
              onPressed: _enterEditMode,
            ),
          ],
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            if (_isEditing)
              AvatarPicker(
                currentImageUrl: _avatarUrl,
                selectedImageBytes: _selectedAvatarBytes,
                displayName: _usernameController.text,
                onImageSelected: (bytes) {
                  setState(() {
                    _selectedAvatarBytes = bytes;
                  });
                },
              )
            else
              UserAvatar(
                avatarUrl: _avatarUrl,
                displayName: _usernameController.text,
                radius: 50,
              ),
            if (_isEditing) ...[
              const SizedBox(height: 8),
              Text(
                'Supports JPEG & PNG (Max 5MB)',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
            const SizedBox(height: 32),
            if (_isEditing)
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(
                    labelText: 'Username', prefixIcon: Icon(Icons.person)),
              )
            else
              _ProfileField(icon: Icons.person, label: 'Username', value: _usernameController.text),
            const SizedBox(height: 16),
            if (_isEditing)
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                    labelText: 'Email', prefixIcon: Icon(Icons.email)),
              )
            else
              _ProfileField(icon: Icons.email, label: 'Email', value: _emailController.text),
            const SizedBox(height: 16),
            if (_isEditing)
              TextField(
                controller: _aboutMeController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'About Me',
                  alignLabelWithHint: true,
                  prefixIcon: Padding(
                    padding: EdgeInsets.only(bottom: 48),
                    child: Icon(Icons.info_outline),
                  ),
                ),
              )
            else
              _ProfileField(
                icon: Icons.info_outline,
                label: 'About Me',
                value: _aboutMeController.text.isEmpty ? 'No bio yet.' : _aboutMeController.text,
              ),
            const SizedBox(height: 32),
            if (_isEditing)
              ElevatedButton(
                onPressed: _isSaving ? null : _saveProfile,
                child: _isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Save Changes',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            if (!_isEditing) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: BorderSide(color: AppColors.primary),
                  minimumSize: const Size(double.infinity, 50),
                ),
                icon: const Icon(Icons.logout),
                label: const Text('Log Out',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                onPressed: () async {
                  await context.read<AuthProvider>().logout();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// A read-only row used to display profile fields that can't be edited (or are
// shown outside of edit mode), styled to look like a disabled input field.
class _ProfileField extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _ProfileField({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.textSecondary.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                const SizedBox(height: 2),
                Text(value, style: TextStyle(fontSize: 16, color: AppColors.textPrimary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
