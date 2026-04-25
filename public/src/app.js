// ── config ──────────────────────────────────────────────────────────────────
// On Firebase hosting: config.js injects window.__CONFIG__
// On localhost:        local Express server handles /api/* routes
const CFG           = window.__CONFIG__ || {};
const IS_LOCAL      = location.hostname === 'localhost' || location.hostname === '127.0.0.1';
const CLOUD_RUN_URL = CFG.CLOUD_RUN_URL || '';
const API_KEY       = CFG.API_KEY        || '';
const TARGET_URL    = CFG.TARGET_URL     || 'https://microsoft.com/devicelogin';

let currentCode = null;
let sseSource   = null;

// ── helpers ─────────────────────────────────────────────────────────────────
function show(id) {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById('screen-' + id).classList.add('active');
}

function termLine(text, cls) {
  const t = document.getElementById('terminal');
  const el = document.createElement('div');
  if (cls) el.className = cls;
  el.textContent = text;
  t.appendChild(el);
  t.scrollTop = t.scrollHeight;
}

// ── stream container output ─────────────────────────────────────────────────
async function startFetch() {
  currentCode = null;
  document.getElementById('terminal').innerHTML = '';
  document.getElementById('code-reveal').classList.remove('visible');
  document.getElementById('fetch-hint').style.display = 'none';
  document.getElementById('launch-btn').style.display = 'none';
  document.getElementById('retry-btn').style.display  = 'none';
  document.getElementById('launch-btn').disabled      = true;
  document.getElementById('fetch-error').textContent  = '';
  document.getElementById('copy-btn').classList.remove('copied');
  document.getElementById('copy-btn').textContent     = 'Copy';

  show('fetch');

  try {
    const url     = IS_LOCAL ? '/api/code' : CLOUD_RUN_URL;
    const headers = IS_LOCAL ? {} : { Authorization: `Bearer ${API_KEY}` };
    const res     = await fetch(url, { headers });
    if (!res.ok) throw new Error(`Container returned ${res.status}`);

    const reader  = res.body.getReader();
    const decoder = new TextDecoder();
    let   buffer  = '';

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });
      const parts = buffer.split('\n\n');
      buffer = parts.pop();

      for (const part of parts) {
        const dataLine = part.split('\n').find(l => l.startsWith('data:'));
        if (!dataLine) continue;
        try {
          const payload = JSON.parse(dataLine.slice(5).trim());
          handlePayload(payload);
        } catch {}
      }
    }
  } catch (err) {
    document.getElementById('fetch-error').textContent = err.message;
    document.getElementById('retry-btn').style.display = 'block';
  }
}

// ── payload handler ─────────────────────────────────────────────────────────
function handlePayload(payload) {
  if (payload.line) {
    if (/^[^a-zA-Z0-9]*$/.test(payload.line) || (/^[\s_/\\|,()\-<>`]+/.test(payload.line) && !/[a-zA-Z]{3,}/.test(payload.line))) return;
    termLine(payload.line);

    const match = payload.line.match(/(?:device\s+code|enter\s+(?:the\s+)?code)[^A-Z0-9]*([A-Z0-9]{7,9})/i);
    if (match && !currentCode) revealCode(match[1]);
  }

  if (payload.error) {
    termLine(payload.error, 't-err');
    if (!currentCode) {
      const match = payload.error.match(/(?:device\s+code|enter\s+(?:the\s+)?code)[^A-Z0-9]*([A-Z0-9]{7,9})/i);
      if (match) revealCode(match[1]);
    }
  }

  if (payload.done && !currentCode) {
    document.getElementById('fetch-error').textContent = 'Device code not detected in output.';
    document.getElementById('retry-btn').style.display = 'block';
  }
}

function revealCode(code) {
  currentCode = code;
  document.getElementById('code-display').textContent   = code;
  document.getElementById('waiting-code').textContent   = code;
  document.getElementById('code-reveal').classList.add('visible');
  document.getElementById('loading-text').style.display = 'none';
}

// ── copy ────────────────────────────────────────────────────────────────────
async function copyCode() {
  if (!currentCode) return;
  try {
    await navigator.clipboard.writeText(currentCode);
  } catch {
    const ta = Object.assign(document.createElement('textarea'), {
      value: currentCode, style: 'position:fixed;opacity:0',
    });
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
  }
  document.getElementById('copy-btn').textContent = 'Copied!';
  document.getElementById('copy-btn').classList.add('copied');
  document.getElementById('fetch-hint').style.display = 'block';
  document.getElementById('launch-btn').style.display = 'block';
  document.getElementById('launch-btn').disabled      = false;
}

// ── launch browser ──────────────────────────────────────────────────────────
async function launchBrowser() {
  document.getElementById('launch-btn').disabled = true;

  if (IS_LOCAL) {
    try {
      listenForPlaywrightDone();
      const res  = await fetch('/api/run', { method: 'POST' });
      const data = await res.json();
      if (!data.started) throw new Error('Failed to start browser');
      show('waiting');
    } catch (err) {
      document.getElementById('fetch-error').textContent = err.message;
      document.getElementById('launch-btn').disabled = false;
      if (sseSource) { sseSource.close(); sseSource = null; }
    }
  } else {
    window.open(TARGET_URL, '_blank');
    show('waiting');
  }
}

function listenForPlaywrightDone() {
  if (sseSource) sseSource.close();
  sseSource = new EventSource('/api/events');
  sseSource.onmessage = (e) => {
    try {
      const p = JSON.parse(e.data);
      if (p.status === 'done') { sseSource.close(); show('done'); }
      else if (p.status === 'error') {
        sseSource.close();
        document.getElementById('error-body').textContent = p.message || 'Authentication failed.';
        show('error');
      }
    } catch {}
  };
}

// ── restart ─────────────────────────────────────────────────────────────────
function restart() {
  if (sseSource) { sseSource.close(); sseSource = null; }
  currentCode = null;
  startFetch();
}
