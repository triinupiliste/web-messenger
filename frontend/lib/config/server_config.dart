// Single place to point the app at the backend.
//
// Configurable at build/run time via --dart-define=SERVER_BASE_URL=..., e.g.:
//   flutter run -d chrome --dart-define=SERVER_BASE_URL=http://localhost:5000
// Falls back to the production Railway URL when not provided.
const String serverBaseUrl = String.fromEnvironment(
  'SERVER_BASE_URL',
  defaultValue: 'https://web-messenger-production-750e.up.railway.app',
);
