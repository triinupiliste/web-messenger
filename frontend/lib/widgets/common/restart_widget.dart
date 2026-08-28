import 'package:flutter/material.dart';

/// Wraps the app so it can be told to rebuild from the top down, used after
/// changing the theme so every built screen picks up the new colors. Takes a
/// builder (not a plain child) so each rebuild constructs a new widget
/// instance. Doesn't change Keys, so Navigator state is preserved.
class RestartWidget extends StatefulWidget {
  final WidgetBuilder builder;

  const RestartWidget({super.key, required this.builder});

  static void restartApp(BuildContext context) {
    context.findAncestorStateOfType<_RestartWidgetState>()?.restartApp();
  }

  @override
  State<RestartWidget> createState() => _RestartWidgetState();
}

class _RestartWidgetState extends State<RestartWidget> {
  void restartApp() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context);
  }
}
