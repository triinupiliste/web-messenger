import { S3Client, PutObjectCommand, GetObjectCommand } from '@aws-sdk/client-s3';
import { Readable } from 'stream';
import { requireEnv } from './env';

const R2_ACCOUNT_ID = requireEnv('R2_ACCOUNT_ID');
const R2_ACCESS_KEY_ID = requireEnv('R2_ACCESS_KEY_ID');
const R2_SECRET_ACCESS_KEY = requireEnv('R2_SECRET_ACCESS_KEY');
const R2_BUCKET_NAME = requireEnv('R2_BUCKET_NAME');

// Cloudflare R2 is S3-API-compatible, so the AWS SDK works against it as-is by
// pointing at R2's endpoint instead of AWS's. Used instead of local disk
// storage because uploads on Railway don't survive redeploys otherwise (every
// deploy starts from a fresh container filesystem, wiping anything written to
// the old local /uploads directory).
const r2Client = new S3Client({
    region: 'auto',
    endpoint: `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
    credentials: {
        accessKeyId: R2_ACCESS_KEY_ID,
        secretAccessKey: R2_SECRET_ACCESS_KEY,
    },
});

// `body` is expected to already be encrypted (see encryption.util.ts) —
// this module only knows about storing/retrieving opaque bytes by key.
export async function uploadObject(key: string, body: Buffer): Promise<void> {
    await r2Client.send(new PutObjectCommand({
        Bucket: R2_BUCKET_NAME,
        Key: key,
        Body: body,
    }));
}

export async function downloadObject(key: string): Promise<Buffer> {
    const result = await r2Client.send(new GetObjectCommand({
        Bucket: R2_BUCKET_NAME,
        Key: key,
    }));
    const stream = result.Body as Readable;
    const chunks: Buffer[] = [];
    for await (const chunk of stream) {
        chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    }
    return Buffer.concat(chunks);
}
