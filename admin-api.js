const express = require('express');
const fs = require('fs');
const path = require('path');

const app = express();
const PORT = process.env.ADMIN_PORT || 8080;
const STREAMS_CONFIG_FILE = path.join(__dirname, 'streams.conf');
const CONTROL_FILE = path.join(__dirname, 'stream', 'control.json');

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

function readStreamsConfig() {
    try {
        if (!fs.existsSync(STREAMS_CONFIG_FILE)) {
            return [];
        }
        
        const content = fs.readFileSync(STREAMS_CONFIG_FILE, 'utf8');
        const streams = [];
        
        content.split('\n').forEach(line => {
            line = line.trim();
            if (line && !line.startsWith('#')) {
                const [name, url] = line.split('|').map(s => s.trim());
                if (name && url) {
                    streams.push({ name, url });
                }
            }
        });
        
        return streams;
    } catch (error) {
        console.error('Error reading streams config:', error);
        return [];
    }
}

function writeStreamsConfig(streams) {
    try {
        const content = streams.map(s => `${s.name}|${s.url}`).join('\n');
        fs.writeFileSync(STREAMS_CONFIG_FILE, content + '\n', 'utf8');
        return true;
    } catch (error) {
        console.error('Error writing streams config:', error);
        return false;
    }
}

function ensureControlDir() {
    const dir = path.dirname(CONTROL_FILE);
    if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
    }
}

function sendReloadSignal() {
    ensureControlDir();
    const signal = {
        action: 'reload',
        timestamp: Date.now()
    };
    fs.writeFileSync(CONTROL_FILE, JSON.stringify(signal), 'utf8');
}

app.get('/api/streams', (req, res) => {
    const streams = readStreamsConfig();
    res.json({ success: true, streams });
});

app.post('/api/streams', (req, res) => {
    const { name, url } = req.body;
    
    if (!name || !url) {
        return res.status(400).json({ success: false, error: 'Name and URL are required' });
    }
    
    if (!/^[a-zA-Z0-9_-]+$/.test(name)) {
        return res.status(400).json({ success: false, error: 'Invalid channel name. Use only letters, numbers, _ and -' });
    }
    
    const streams = readStreamsConfig();
    
    if (streams.find(s => s.name === name)) {
        return res.status(400).json({ success: false, error: 'Channel name already exists' });
    }
    
    streams.push({ name, url });
    
    if (writeStreamsConfig(streams)) {
        sendReloadSignal();
        res.json({ success: true, message: 'Channel added successfully' });
    } else {
        res.status(500).json({ success: false, error: 'Failed to save configuration' });
    }
});

app.put('/api/streams/:name', (req, res) => {
    const oldName = req.params.name;
    const { name, url } = req.body;
    
    if (!name || !url) {
        return res.status(400).json({ success: false, error: 'Name and URL are required' });
    }
    
    if (!/^[a-zA-Z0-9_-]+$/.test(name)) {
        return res.status(400).json({ success: false, error: 'Invalid channel name' });
    }
    
    const streams = readStreamsConfig();
    const index = streams.findIndex(s => s.name === oldName);
    
    if (index === -1) {
        return res.status(404).json({ success: false, error: 'Channel not found' });
    }
    
    if (name !== oldName && streams.find(s => s.name === name)) {
        return res.status(400).json({ success: false, error: 'New channel name already exists' });
    }
    
    streams[index] = { name, url };
    
    if (writeStreamsConfig(streams)) {
        sendReloadSignal();
        res.json({ success: true, message: 'Channel updated successfully' });
    } else {
        res.status(500).json({ success: false, error: 'Failed to save configuration' });
    }
});

app.delete('/api/streams/:name', (req, res) => {
    const name = req.params.name;
    const streams = readStreamsConfig();
    const filteredStreams = streams.filter(s => s.name !== name);
    
    if (filteredStreams.length === streams.length) {
        return res.status(404).json({ success: false, error: 'Channel not found' });
    }
    
    if (writeStreamsConfig(filteredStreams)) {
        sendReloadSignal();
        res.json({ success: true, message: 'Channel deleted successfully' });
    } else {
        res.status(500).json({ success: false, error: 'Failed to save configuration' });
    }
});

app.get('/api/status', (req, res) => {
    const streams = readStreamsConfig();
    res.json({
        success: true,
        totalChannels: streams.length,
        uptime: process.uptime(),
        timestamp: Date.now()
    });
});

app.listen(PORT, '127.0.0.1', () => {
    console.log(`🎛️  Admin API running on http://127.0.0.1:${PORT}`);
    console.log(`📝 Streams config: ${STREAMS_CONFIG_FILE}`);
    console.log(`⚠️  لوحة التحكم مفتوحة بدون مصادقة`);
});
