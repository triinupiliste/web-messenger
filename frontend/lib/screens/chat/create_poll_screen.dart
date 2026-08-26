import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

// Collects a poll's question/options/settings, then hands the result back to
// the caller (ChatRoomScreen), which handles actually creating the poll and
// sending its chat message.
class CreatePollScreen extends StatefulWidget {
  const CreatePollScreen({super.key});

  @override
  State<CreatePollScreen> createState() => _CreatePollScreenState();
}

class _CreatePollScreenState extends State<CreatePollScreen> {
  static const int _maxOptions = 10;

  final TextEditingController _questionController = TextEditingController();
  final List<TextEditingController> _optionControllers = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _isAnonymous = false;
  bool _allowMultipleAnswers = false;

  @override
  void dispose() {
    _questionController.dispose();
    for (final c in _optionControllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _addOption() {
    if (_optionControllers.length >= _maxOptions) return;
    setState(() => _optionControllers.add(TextEditingController()));
  }

  void _removeOption(int index) {
    setState(() {
      final removed = _optionControllers.removeAt(index);
      removed.dispose();
    });
  }

  bool get _isValid {
    if (_questionController.text.trim().isEmpty) return false;
    final nonEmptyOptions = _optionControllers.where((c) => c.text.trim().isNotEmpty).length;
    return nonEmptyOptions >= 2;
  }

  void _submit() {
    final options = _optionControllers
        .map((c) => c.text.trim())
        .where((text) => text.isNotEmpty)
        .toList();

    Navigator.pop(context, {
      'question': _questionController.text.trim(),
      'options': options,
      'isAnonymous': _isAnonymous,
      'allowMultipleAnswers': _allowMultipleAnswers,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Poll')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _questionController,
            maxLength: 300,
            maxLines: null,
            decoration: const InputDecoration(
              labelText: 'Question',
              hintText: 'Ask a question...',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          const Text('Options', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (var i = 0; i < _optionControllers.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _optionControllers[i],
                      maxLength: 100,
                      decoration: InputDecoration(
                        labelText: 'Option ${i + 1}',
                        border: const OutlineInputBorder(),
                        counterText: '',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  if (_optionControllers.length > 2)
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                      onPressed: () => _removeOption(i),
                    ),
                ],
              ),
            ),
          if (_optionControllers.length < _maxOptions)
            TextButton.icon(
              onPressed: _addOption,
              icon: Icon(Icons.add, color: AppColors.primary),
              label: Text('Add option', style: TextStyle(color: AppColors.primary)),
            ),
          const Divider(height: 32),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Anonymous voting'),
            subtitle: const Text('Voter identities are hidden, only totals are shown'),
            value: _isAnonymous,
            onChanged: (v) => setState(() => _isAnonymous = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Allow multiple answers'),
            subtitle: const Text('Voters can select more than one option'),
            value: _allowMultipleAnswers,
            onChanged: (v) => setState(() => _allowMultipleAnswers = v),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _isValid ? _submit : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text('Create Poll'),
          ),
        ],
      ),
    );
  }
}
