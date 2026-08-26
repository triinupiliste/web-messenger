import { escapeHtml } from '../utils/html.util';

interface SendMailOptions {
    to: string;
    subject: string;
    html: string;
    text: string;
}

interface AccountEmailOptions {
    to: string;
    username: string;
    token: string;
}

interface BrevoResponse {
    messageId?: string;
    message?: string;
    code?: string;
}

function getBaseUrl(): string {
    return (process.env.APP_BASE_URL || 'http://localhost:5000/api').replace(/\/$/, '');
}

async function sendMail({ to, subject, html, text }: SendMailOptions): Promise<BrevoResponse> {
    const apiKey = process.env.BREVO_API_KEY;
    const fromEmail = process.env.MAIL_FROM;

    if (!apiKey) throw new Error('BREVO_API_KEY is missing.');
    if (!fromEmail) throw new Error('MAIL_FROM is missing.');

    const response = await fetch('https://api.brevo.com/v3/smtp/email', {
        method: 'POST',
        headers: {
            accept: 'application/json',
            'api-key': apiKey,
            'content-type': 'application/json',
        },
        body: JSON.stringify({
            sender: {
                name: process.env.MAIL_FROM_NAME || 'Web Messenger',
                email: fromEmail,
            },
            to: [{ email: to }],
            subject,
            textContent: text,
            htmlContent: html,
        }),
    });

    const data = await response.json() as BrevoResponse;
    if (!response.ok) {
        throw new Error(data.message || `Brevo returned HTTP ${response.status}.`);
    }

    return data;
}

export async function sendVerificationEmail({
    to,
    username,
    token,
}: AccountEmailOptions): Promise<BrevoResponse> {
    const verifyUrl = `${getBaseUrl()}/auth/verify-email?token=${encodeURIComponent(token)}`;
    const safeUsername = escapeHtml(username);

    return sendMail({
        to,
        subject: 'Verify your Web Messenger account',
        text: `Hi ${username}, verify your account using this link: ${verifyUrl}`,
        html: `<p>Hi ${safeUsername},</p><p>Verify your account by clicking <a href="${verifyUrl}">this link</a>.</p><p>This link expires in 24 hours.</p>`,
    });
}

export async function sendPasswordResetEmail({
    to,
    username,
    token,
}: AccountEmailOptions): Promise<BrevoResponse> {
    const resetUrl = `${getBaseUrl()}/auth/reset-password?token=${encodeURIComponent(token)}`;
    const safeUsername = escapeHtml(username);

    return sendMail({
        to,
        subject: 'Reset your Web Messenger password',
        text: `Hi ${username}, reset your password using this link: ${resetUrl}`,
        html: `<p>Hi ${safeUsername},</p><p>Reset your password by clicking <a href="${resetUrl}">this link</a>.</p>`,
    });
}