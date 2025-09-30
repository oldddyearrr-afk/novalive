const express = require('express');
const WebSocket = require('ws');
const http = require('http');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

const PORT = process.env.SIGNALING_PORT || 9000;
const BIND_HOST = process.env.BIND_HOST || '127.0.0.1';

const rooms = new Map();

wss.on('connection', (ws) => {
    let currentRoom = null;
    let peerId = null;

    ws.peerId = null;

    ws.on('message', (message) => {
        try {
            const data = JSON.parse(message);

            switch (data.type) {
                case 'join':
                    currentRoom = data.room;
                    peerId = data.peerId;
                    ws.peerId = peerId;

                    if (!rooms.has(currentRoom)) {
                        rooms.set(currentRoom, new Map());
                    }
                    
                    const room = rooms.get(currentRoom);
                    room.set(peerId, ws);

                    const peerList = Array.from(room.keys())
                        .filter(id => id !== peerId && room.get(id).readyState === WebSocket.OPEN);

                    ws.send(JSON.stringify({
                        type: 'peers',
                        peers: peerList
                    }));

                    room.forEach((peer, id) => {
                        if (id !== peerId && peer.readyState === WebSocket.OPEN) {
                            peer.send(JSON.stringify({
                                type: 'peer-joined',
                                peerId: peerId
                            }));
                        }
                    });

                    console.log(`Peer ${peerId} joined room ${currentRoom}. Total: ${room.size}`);
                    break;

                case 'signal':
                    if (currentRoom && rooms.has(currentRoom) && data.targetPeerId) {
                        const room = rooms.get(currentRoom);
                        const targetPeer = room.get(data.targetPeerId);
                        if (targetPeer && targetPeer.readyState === WebSocket.OPEN) {
                            targetPeer.send(JSON.stringify({
                                type: 'signal',
                                peerId: peerId,
                                signal: data.signal
                            }));
                        }
                    }
                    break;
            }
        } catch (err) {
            console.error('Message error:', err);
        }
    });

    ws.on('close', () => {
        if (currentRoom && rooms.has(currentRoom) && peerId) {
            const room = rooms.get(currentRoom);
            room.delete(peerId);

            room.forEach((peer, id) => {
                if (peer.readyState === WebSocket.OPEN) {
                    peer.send(JSON.stringify({
                        type: 'peer-left',
                        peerId: peerId
                    }));
                }
            });

            console.log(`Peer ${peerId} left room ${currentRoom}. Remaining: ${room.size}`);

            if (room.size === 0) {
                rooms.delete(currentRoom);
            }
        }
    });

    ws.on('error', (error) => {
        console.error('WebSocket error:', error);
    });
});

app.get('/stats', (req, res) => {
    const stats = {};
    rooms.forEach((peers, room) => {
        stats[room] = {
            count: peers.size,
            peers: Array.from(peers.keys())
        };
    });
    res.json({
        rooms: Object.keys(stats).length,
        roomDetails: stats,
        totalPeers: Array.from(rooms.values()).reduce((sum, room) => sum + room.size, 0)
    });
});

server.listen(PORT, BIND_HOST, () => {
    console.log(`🔗 P2P Signaling Server running on ${BIND_HOST}:${PORT}`);
});
