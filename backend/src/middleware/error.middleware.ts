import { Request, Response, NextFunction } from 'express';
import { logger } from '../utils/logger.util';

// Errors reaching this boundary can come from anywhere (thrown values aren't
// guaranteed to be Error instances), so the input is deliberately `unknown`
// and narrowed before use rather than trusted as `any`.
interface HttpError {
    statusCode?: number;
    message?: string;
    stack?: string;
}

function isHttpError(err: unknown): err is HttpError {
    return typeof err === 'object' && err !== null;
}

export function errorHandler(
    err: unknown,
    req: Request,
    res: Response,
    next: NextFunction
): void {
    logger.error('Global error caught:', err);

    const httpError = isHttpError(err) ? err : {};
    const statusCode = httpError.statusCode || 500;

    // Security: Never leak raw internal error messages for 500 server crashes in production
    const message = (statusCode === 500 && process.env.NODE_ENV === 'production')
        ? 'Internal Server Error'
        : (httpError.message || 'Internal Server Error');

    res.status(statusCode).json({
        error: message,
        // Include stack trace only if running in development mode
        ...(process.env.NODE_ENV === 'development' && { stack: httpError.stack }),
    });
}