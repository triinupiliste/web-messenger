import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/invite_provider.dart';
import 'services/notification_service.dart';
import 'services/push_notification_service.dart';
import 'services/theme_service.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home/home_screen.dart';
import 'widgets/common/restart_widget.dart';

void main() {
  // App-wide crash safety net for genuinely unexpected/uncaught errors, on top of
  // screens' own try/catch + SnackBars for expected failures.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Framework build/layout/paint errors are normally only printed to the console
    // in release mode while leaving the broken widget on screen.
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
    };

    // Catches errors that reach the engine directly (e.g. platform channel callbacks)
    // outside of the zone below.
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('Uncaught platform error: $error\n$stack');
      return true;
    };

    // Replaces the default red "Error" screen with a stable, branded fallback.
    ErrorWidget.builder = (FlutterErrorDetails details) => const _CrashFallbackScreen();

    // Apply the user's previously chosen theme (if any) before the first
    // frame, so the app doesn't flash the default theme then swap.
    await ThemeService.loadSavedTheme();

    // Firebase Cloud Messaging push notifications aren't wired up for the web
    // build yet (that needs a separate Firebase Web App registration, VAPID
    // key, and a service worker) — skip it there so startup doesn't throw.
    // The web app still gets real-time updates via the socket connection
    // while it's open; PushNotificationService.init() also no-ops on web.
    if (!kIsWeb) {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    }
    // Not const: RestartWidget's builder must construct a fresh MyApp instance on
    // every rebuild, otherwise a const instance is reused and theme refreshes no-op.
    runApp(RestartWidget(builder: (context) => MyApp()));
  }, (error, stackTrace) {
    // Catches uncaught async errors (e.g. Futures/Timers/socket callbacks)
    // that would otherwise crash the isolate.
    debugPrint('Uncaught error: $error\n$stackTrace');
  });
}

class _CrashFallbackScreen extends StatelessWidget {
  const _CrashFallbackScreen();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: AppColors.error),
              const SizedBox(height: 12),
              Text(
                'Something went wrong',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 4),
              Text(
                'Please try again.',
                style: TextStyle(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              // Pops back to the root route and forces a full rebuild via RestartWidget,
              // the same mechanism used to apply theme changes app-wide.
              ElevatedButton(
                onPressed: () {
                  Navigator.of(context).popUntil((route) => route.isFirst);
                  RestartWidget.restartApp(context);
                },
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Only 'resumed' means the app is actually visible/interactive — a chat screen
  // underneath may still be mounted with its socket listeners registered even
  // while backgrounded/locked.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLifecycleTracker.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ChatProvider()),
        ChangeNotifierProvider(create: (_) => InviteProvider()),
      ],
      child: MaterialApp(
        navigatorKey: PushNotificationService.navigatorKey,
        title: 'Mobile Messenger',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.theme,
        home: Consumer<AuthProvider>(
          builder: (context, authProvider, _) {
            if (authProvider.isLoading) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            return authProvider.isAuthenticated
                ? HomeScreen(key: HomeScreen.homeKey)
                : const LoginScreen();
          },
        ),
      ),
    );
  }
}