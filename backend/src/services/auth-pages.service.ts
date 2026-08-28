// Renders the verify-email / reset-password HTML pages a user reaches by
// tapping an email link — mirrors the Flutter app's look and feel. Kept
// separate from AuthController so the controller only orchestrates auth logic.
import { escapeHtml } from '../utils/html.util';

const BRAND = {
    background: '#FFF5F2',
    surface: '#FFFFFF',
    primary: '#FF6B6B',
    primaryDark: '#D15858',
    textPrimary: '#2D3142',
    textSecondary: '#8D99AE',
    cardBorder: '#EDEDF2',
    errorBackground: '#FFEBEE',
    errorBorder: '#EF9A9A',
    errorText: '#C62828',
};

const CHECK_ICON = '<svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>';
const ERROR_ICON = '<svg width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6 6 18M6 6l12 12"/></svg>';
const LOCK_ICON = '<svg width="30" height="30" viewBox="0 0 24 24" fill="#fff"><path d="M12 1a5 5 0 0 0-5 5v3H6a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-9a2 2 0 0 0-2-2h-1V6a5 5 0 0 0-5-5Zm-3 8V6a3 3 0 1 1 6 0v3H9Zm3 4a2 2 0 0 1 1 3.73V19a1 1 0 1 1-2 0v-1.27A2 2 0 0 1 12 13Z"/></svg>';

function pageShell(title: string, bodyHtml: string): string {
    return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title><link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link href="https://fonts.googleapis.com/css2?family=Manrope:wght@500;700;800&display=swap" rel="stylesheet"><style>
body{margin:0;font-family:'Manrope',Arial,sans-serif;background:${BRAND.background};color:${BRAND.textPrimary};padding:40px 20px;display:flex;min-height:100vh;box-sizing:border-box}
main{max-width:420px;margin:auto;background:${BRAND.surface};padding:36px 32px;border-radius:24px;box-shadow:0 12px 32px rgba(45,49,66,0.08);text-align:center;width:100%;box-sizing:border-box}
.badge{width:72px;height:72px;border-radius:50%;margin:0 auto 20px;display:flex;align-items:center;justify-content:center;background:linear-gradient(135deg,${BRAND.primary},${BRAND.primaryDark});box-shadow:0 8px 20px rgba(255,107,107,0.35)}
h1{margin:0 0 10px;font-size:22px;font-weight:800}
p{margin:0 0 8px;font-size:15px;line-height:1.5;color:${BRAND.textSecondary}}
.error-banner{background:${BRAND.errorBackground};border:1px solid ${BRAND.errorBorder};color:${BRAND.errorText};border-radius:14px;padding:12px 14px;font-size:14px;font-weight:700;text-align:left;margin:18px 0 0}
form{text-align:left;margin-top:22px}
label{display:block;font-weight:700;font-size:14px;margin:0 0 8px}
input[type=password]{box-sizing:border-box;border:1px solid ${BRAND.cardBorder};background:${BRAND.background};border-radius:14px;font-family:inherit;font-size:16px;padding:14px;width:100%;color:${BRAND.textPrimary}}
input[type=password]:focus{outline:2px solid ${BRAND.primary};outline-offset:1px}
button{background:linear-gradient(135deg,${BRAND.primary},${BRAND.primaryDark});border:0;border-radius:14px;color:#fff;cursor:pointer;font-family:inherit;font-size:16px;font-weight:800;margin-top:20px;padding:14px;width:100%}
</style></head><body><main>${bodyHtml}</main></body></html>`;
}

export function verificationPage(title: string, message: string, successful: boolean): string {
    const icon = successful ? CHECK_ICON : ERROR_ICON;
    return pageShell(title, `<div class="badge">${icon}</div><h1>${title}</h1><p>${message}</p><p>You may now return to Web & Mobile Messenger.</p>`);
}

export function resetPasswordPage(rawToken: string, errorMessage?: string): string {
    const safeToken = escapeHtml(rawToken);
    const errorBlock = errorMessage
        ? `<div class="error-banner">${escapeHtml(errorMessage)}</div>`
        : '';

    return pageShell('Reset password', `<div class="badge">${LOCK_ICON}</div><h1>Choose a new password</h1><p>Enter a new password for your Web & Mobile Messenger account.</p>${errorBlock}<form method="post" action="/api/auth/reset-password"><input type="hidden" name="token" value="${safeToken}"><label for="password">New password</label><input id="password" name="password" type="password" autocomplete="new-password" minlength="8" required><button type="submit">Reset password</button></form>`);
}
