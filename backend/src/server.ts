import express from 'express';
import http from 'http';
import { Server } from 'socket.io';
import cors from 'cors';
import dotenv from 'dotenv';

import authRoutes from './routes/auth.routes';
import userRoutes from './routes/user.routes';
import inviteRoutes from './routes/invite.routes';
import chatRoutes from './routes/chat.routes';
import mediaRoutes from './routes/media.routes';
import { MediaController } from './controllers/media.controller';
import { errorHandler } from './middleware/error.middleware';
import { verifyMediaToken } from './middleware/auth.middleware';
import { registerChatHandlers } from './sockets/chat.socket';
import { setIO } from './sockets/socket.instance';
import { runMigrations } from './config/migrate';
import { isOriginAllowed } from './config/env';
import { logger } from './utils/logger.util';

dotenv.config();

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
    cors: {
        origin: (origin, callback) => callback(null, isOriginAllowed(origin)),
        methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE']
    }
});
setIO(io);


app.use(cors({ origin: (origin, callback) => callback(null, isOriginAllowed(origin)) }));
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Files are stored encrypted at rest, so this decrypts on the fly. Requires
// a valid JWT so media can't be fetched by guessing a filename.
app.get('/uploads/:filename', verifyMediaToken, MediaController.getMedia);

app.get('/', (req, res) => {
    res.status(200).json({ status: 'ok', message: 'Mobile Messenger API is running' });
});

app.use('/api/auth', authRoutes);
app.use('/api/users', userRoutes);
app.use('/api/invites', inviteRoutes);
app.use('/api/chats', chatRoutes);
app.use('/api/media', mediaRoutes);

app.use(errorHandler);

registerChatHandlers(io);

const PORT = process.env.PORT || 5000;

// Ensures schema exists before accepting requests — critical for fresh
// deploys on managed hosts (e.g. Railway) that start with no tables.
runMigrations()
    .catch((err) => {
        logger.error('Failed to run database migrations:', err);
        process.exit(1);
    })
    .then(() => {
        server.listen(Number(PORT), '0.0.0.0', () => {
            logger.info(`Backend server running on port ${PORT}`);
        });
    });

export default server;