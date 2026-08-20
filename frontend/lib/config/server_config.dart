// Single place to point the app at the backend.
//
// Configurable at build/run time via --dart-define=SERVER_BASE_URL=... so the
// same codebase can target different backends (local dev, ngrok, production
// web deployment) without editing this file and rebuilding from scratch, e.g.:
//   flutter run -d chrome --dart-define=SERVER_BASE_URL=http://localhost:5000
//   flutter build web --dart-define=SERVER_BASE_URL=https://your-host
// Falls back to the production Railway URL when not provided, so existing
// mobile release builds keep working unchanged.
//
// - USB-tethered single device + `adb reverse tcp:5000 tcp:5000`:
//     'http://127.0.0.1:5000'
// - Two+ real phones on their own networks, backend exposed via ngrok:
//     'https://<your-subdomain>.ngrok-free.app'
const String serverBaseUrl = String.fromEnvironment(
  'SERVER_BASE_URL',
  defaultValue: 'https://mobile-messenger-production.up.railway.app',
);
