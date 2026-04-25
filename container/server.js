const express  = require('express');
const { spawn } = require('child_process');
const path     = require('path');
const fs       = require('fs');

const app      = express();
const PORT     = process.env.PORT     || 8080;
const API_KEY  = process.env.API_KEY  || '';
const PWSH_CMD = process.env.PWSH_CMD || '';
const SCRIPT   = path.join(__dirname, 'get-code.ps1');

const CORS_HEADERS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Authorization',
};

// handle preflight for all routes
app.options('*', (req, res) => {
  res.set(CORS_HEADERS).sendStatus(204);
});

// GET /health — no auth, Cloud Run probe
app.get('/health', (_req, res) => res.json({ ok: true }));

// bearer token auth on all other routes
app.use((req, res, next) => {
  const auth = req.headers['authorization'] || '';
  if (auth !== `Bearer ${API_KEY}`) {
    return res.set(CORS_HEADERS).status(401).json({ error: 'Unauthorized' });
  }
  next();
});

// GET /code — streams PowerShell output as SSE
// Each stdout line → { line }
// Each stderr line → { error }
// On exit          → { done, exitCode }
app.get('/code', (req, res) => {
  res.set({ ...CORS_HEADERS, 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'Connection': 'keep-alive' });
  res.flushHeaders();

  const args = PWSH_CMD
    ? ['-NoProfile', '-NonInteractive', '-Command', PWSH_CMD]
    : ['-NoProfile', '-NonInteractive', '-File', SCRIPT];

  const ps = spawn('pwsh', args, { env: process.env });

  const send = (payload) => res.write(`data: ${JSON.stringify(payload)}\n\n`);

  ps.stdout.on('data', (chunk) => {
    chunk.toString().split('\n').forEach((line) => {
      if (line.trim()) send({ line: line.trim() });
    });
  });

  ps.stderr.on('data', (chunk) => {
    chunk.toString().split('\n').forEach((line) => {
      if (line.trim()) send({ error: line.trim() });
    });
  });

  ps.on('close', (code) => {
    send({ done: true, exitCode: code });
    res.end();
  });

  req.on('close', () => ps.kill());
});

// GET /logs — returns the NDJSON log as a parsed array. Raw token blobs that
// PWSH_CMD wrote directly get wrapped into the standard {timestamp, tenant,
// entry} shape on the fly — full token fields preserved.
app.get('/logs', (_req, res) => {
  res.set(CORS_HEADERS);
  const logFile = path.join('/app/logs', 'response.json');
  if (!fs.existsSync(logFile)) return res.status(404).json({ error: 'No response logged yet' });

  const wrapRawToken = (obj) => ({
    timestamp: new Date().toISOString(),
    tenant: process.env.TENANT_ID || 'common',
    entry: { mode: 'pwsh-cmd-token', ...obj },
  });

  const raw = fs.readFileSync(logFile, 'utf8');
  const entries = [];
  const malformed = [];
  for (const line of raw.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let obj;
    try {
      obj = JSON.parse(trimmed);
    } catch {
      malformed.push(trimmed);
      continue;
    }
    if (obj && (obj.access_token || obj.token_type) && !obj.entry) {
      entries.push(wrapRawToken(obj));
    } else {
      entries.push(obj);
    }
  }

  res.setHeader('Content-Type', 'application/json');
  res.json({ count: entries.length, entries, malformed });
});

app.listen(PORT, () => console.log(`code-service listening on :${PORT}`));
