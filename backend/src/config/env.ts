// Fail fast on a missing secret instead of falling back to an insecure
// default (previously broke decryption on restart / allowed forged JWTs).
function requireEnv(name: string): string {
    const value = process.env[name];
    if (!value) {
        throw new Error(
            `Missing required environment variable: ${name}. Set it in your ` +
            `environment (e.g. Railway's Variables tab, or docker-compose.yml ` +
            `for local dev) before starting the server.`,
        );
    }
    return value;
}

export const JWT_SECRET = requireEnv('JWT_SECRET');
export const ENCRYPTION_KEY = requireEnv('ENCRYPTION_KEY');

// Origins allowed to call the API/Socket.IO from a browser — stops a
// malicious web page from making authenticated requests on a victim's behalf.
const DEFAULT_ALLOWED_ORIGINS = [
    'https://web-messenger-production-750e.up.railway.app',
    'https://web-messenger.up.railway.app/',
    'https://mobile-messenger-production.up.railway.app',
    'http://localhost:5000',
    'http://127.0.0.1:5000',
];

export const ALLOWED_ORIGINS = process.env.ALLOWED_ORIGINS
    ? process.env.ALLOWED_ORIGINS.split(',').map((origin) => origin.trim())
    : DEFAULT_ALLOWED_ORIGINS;

// Matches any localhost/127.0.0.1 origin regardless of port — outside of
// production this lets `flutter run -d chrome` (which picks a random dev
// server port on every run) talk to a locally-run backend without having to
// add every port to ALLOWED_ORIGINS by hand. Never applied in production.
const LOCAL_DEV_ORIGIN_PATTERN = /^https?:\/\/(localhost|127\.0\.0\.1):\d+$/;

export function isOriginAllowed(origin: string | undefined): boolean {
    // No Origin header at all means a non-browser client (the mobile app,
    // curl, server-to-server) — those aren't subject to CORS anyway.
    if (!origin) return true;
    if (ALLOWED_ORIGINS.includes(origin)) return true;
    if (process.env.NODE_ENV !== 'production' && LOCAL_DEV_ORIGIN_PATTERN.test(origin)) return true;
    return false;
}
