import { Request, Response, NextFunction } from 'express';
import path from 'path';
import { generateStoredFilename } from '../middleware/upload.middleware';
import { uploadObject, downloadObject } from '../config/storage';
import { encryptBuffer, decryptBuffer } from '../utils/encryption.util';
import { compressVideo } from '../utils/video.util';
import { logger } from '../utils/logger.util';
import { MAX_MEDIA_SIZE_BYTES } from '../config/constants';

const VIDEO_EXTENSIONS = new Set(['.mp4', '.mov', '.avi', '.mkv', '.webm', '.m4v', '.3gp']);

const MIME_TYPES_BY_EXTENSION: Record<string, string> = {
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.png': 'image/png',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.mp4': 'video/mp4',
    '.mov': 'video/quicktime',
    '.avi': 'video/x-msvideo',
    '.mkv': 'video/x-matroska',
    '.webm': 'video/webm',
    '.m4v': 'video/x-m4v',
    '.3gp': 'video/3gpp',
    '.mp3': 'audio/mpeg',
    '.m4a': 'audio/mp4',
    '.wav': 'audio/wav',
    '.aac': 'audio/aac',
    '.ogg': 'audio/ogg',
    // Browser-recorded voice messages (Opus-in-WebM) — named '.weba' rather
    // than '.webm' so it isn't mistaken for a video and sent through ffmpeg.
    '.weba': 'audio/webm',
};

export class MediaController {
    static async uploadMedia(req: Request, res: Response, next: NextFunction): Promise<void> {
        try {
            const file = req.file;

            if (!file) {
                res.status(400).json({ error: 'No file was uploaded.' });
                return;
            }

            let buffer = file.buffer;
            let originalName = file.originalname;
            const extension = path.extname(originalName).toLowerCase();
            const isVideo = VIDEO_EXTENSIONS.has(extension);

            if (isVideo) {
                try {
                    buffer = await compressVideo(buffer, extension);
                    // ffmpeg always outputs an MP4 container regardless of the
                    // input format, so reflect that in the stored filename.
                    originalName = `${path.parse(originalName).name}.mp4`;
                } catch (error) {
                    // Fall back to the original file rather than failing the send — the size
                    // check below still guards against anything too large.
                    logger.error('Video compression failed, storing original file instead:', error);
                    buffer = file.buffer;
                }
            }

            if (buffer.length > MAX_MEDIA_SIZE_BYTES) {
                const message = isVideo
                    ? 'This video is too large to send even after compression. Try a shorter clip.'
                    : 'Media file size exceeds the 20MB limit.';
                res.status(413).json({ error: message });
                return;
            }

            // Encrypt the raw file bytes before they ever touch storage.
            const filename = generateStoredFilename(originalName);
            const encrypted = encryptBuffer(buffer);
            await uploadObject(filename, encrypted);

            // Returned as a relative path, not a full URL — the host (e.g. an ngrok
            // tunnel) can change between restarts, which would break stored URLs otherwise.
            const url = `/uploads/${filename}`;

            res.status(201).json({ url });
        } catch (error) {
            next(error);
        }
    }

    // Decrypts a stored media file on the fly and streams it back (replaces
    // serving /uploads via express.static now that files are encrypted at rest).
    static async getMedia(req: Request, res: Response): Promise<void> {
        const filename = req.params.filename;

        // Guard against path traversal — only allow plain filenames we generated ourselves.
        if (!filename || filename.includes('/') || filename.includes('\\') || filename.includes('..')) {
            res.status(400).json({ error: 'Invalid file name.' });
            return;
        }

        try {
            const encrypted = await downloadObject(filename);
            const decrypted = decryptBuffer(encrypted);
            const contentType = MIME_TYPES_BY_EXTENSION[path.extname(filename).toLowerCase()] || 'application/octet-stream';
            const totalSize = decrypted.length;

            res.setHeader('Content-Type', contentType);
            res.setHeader('Cache-Control', 'private, max-age=86400');
            // Required for video seeking/thumbnail extraction — Android's
            // MediaMetadataRetriever and video players need to fetch specific byte ranges.
            res.setHeader('Accept-Ranges', 'bytes');

            const rangeHeader = req.headers.range;
            if (rangeHeader) {
                const match = /^bytes=(\d*)-(\d*)$/.exec(rangeHeader);
                let start = match && match[1] ? parseInt(match[1], 10) : NaN;
                let end = match && match[2] ? parseInt(match[2], 10) : NaN;

                if (!match || (Number.isNaN(start) && Number.isNaN(end))) {
                    res.status(416).setHeader('Content-Range', `bytes */${totalSize}`).end();
                    return;
                }
                if (Number.isNaN(start)) {
                    // Suffix range, e.g. "bytes=-500" -> last 500 bytes.
                    start = Math.max(totalSize - end, 0);
                    end = totalSize - 1;
                } else if (Number.isNaN(end)) {
                    end = totalSize - 1;
                }

                if (start > end || start >= totalSize) {
                    res.status(416).setHeader('Content-Range', `bytes */${totalSize}`).end();
                    return;
                }
                end = Math.min(end, totalSize - 1);

                res.status(206);
                res.setHeader('Content-Range', `bytes ${start}-${end}/${totalSize}`);
                res.setHeader('Content-Length', String(end - start + 1));
                res.send(decrypted.subarray(start, end + 1));
                return;
            }

            res.setHeader('Content-Length', String(totalSize));
            res.status(200).send(decrypted);
        } catch (error) {
            res.status(404).json({ error: 'File not found.' });
        }
    }
}
