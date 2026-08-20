// One row per logged-in device/browser. Replaces the older global
// `users.session_version` counter, which only allowed a single active
// session and force-logged-out every other device on a new login.
export interface Session {
    id: string;
    user_id: string;
    platform: string; // 'mobile' | 'web'
    device_name: string | null;
    created_at: Date;
    last_seen_at: Date;
    revoked_at: Date | null;
}
