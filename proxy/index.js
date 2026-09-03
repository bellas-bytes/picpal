/**
 * picpal-vlm-proxy  —  Local dev proxy for Claude Sonnet 5 vision calls.
 *
 * Accepts: POST /analyze  (multipart/form-data)
 *   Fields:  image  — JPEG bytes
 *            prompt — plain-text string
 *
 * Returns: { "result": "<model text>" }  on success (HTTP 200)
 *          { "error":  "<message>"     }  on failure (HTTP 4xx/5xx)
 *
 * Security: API key is read exclusively from process.env.ANTHROPIC_API_KEY.
 *           Image bytes are NEVER logged.
 */

'use strict';

import Anthropic from '@anthropic-ai/sdk';
import express from 'express';
import rateLimit from 'express-rate-limit';
import multer from 'multer';
import { readFileSync, writeFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

// ── Named constants ────────────────────────────────────────────────────────────
const PORT                 = 4000;
const MODEL_ID             = 'claude-sonnet-5';
const MAX_TOKENS           = 64;    // ≤15-word reply ≈ 20 tokens; 64 gives headroom
const RATE_LIMIT_WINDOW_MS = 60_000;   // 1 minute per rolling window
const RATE_LIMIT_MAX_CALLS = 20;       // max calls per IP per window
const HARD_CALL_CEILING    = 200;      // total calls this process lifetime
const MAX_IMAGE_BYTES      = 5 * 1024 * 1024; // 5 MB per upload

// ── Persistent call counter ────────────────────────────────────────────────────
const __dirname = dirname(fileURLToPath(import.meta.url));
const CALL_COUNTER_PATH = join(__dirname, '.call-counter.json');

function loadCallCount() {
  try {
    const raw = readFileSync(CALL_COUNTER_PATH, 'utf8');
    const parsed = JSON.parse(raw);
    return typeof parsed.totalCalls === 'number' ? parsed.totalCalls : 0;
  } catch {
    return 0;
  }
}

function saveCallCount(count) {
  try {
    writeFileSync(CALL_COUNTER_PATH, JSON.stringify({ totalCalls: count }), 'utf8');
  } catch (err) {
    console.error('[picpal-proxy] Failed to persist call counter:', err?.message);
  }
}

let totalCalls = loadCallCount();

// ── Anthropic client ───────────────────────────────────────────────────────────
// Key is read from environment only — never hardcoded.
const anthropic = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });

// ── Express app ────────────────────────────────────────────────────────────────
const app = express();

// Per-IP rate limiter (independent of any client-side gate)
const limiter = rateLimit({
  windowMs: RATE_LIMIT_WINDOW_MS,
  max: RATE_LIMIT_MAX_CALLS,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Rate limit exceeded. Try again shortly.' },
});
app.use('/analyze', limiter);

// Multer — in-memory storage, JPEG only
const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: MAX_IMAGE_BYTES },
  fileFilter: (_req, file, cb) => {
    if (file.mimetype === 'image/jpeg' || file.mimetype === 'image/jpg') {
      cb(null, true);
    } else {
      cb(new Error('Only JPEG images are accepted.'));
    }
  },
});

// ── POST /analyze ──────────────────────────────────────────────────────────────
app.post('/analyze', upload.fields([{ name: 'image', maxCount: 1 }, { name: 'reference', maxCount: 1 }]), async (req, res) => {
  try {
    // Hard call ceiling — enforced server-side, independent of client-side gate
    if (totalCalls >= HARD_CALL_CEILING) {
      return res
        .status(503)
        .json({ error: 'Hard call ceiling reached. Restart the proxy to reset.' });
    }

    const { prompt } = req.body;
    const imageFile = req.files['image']?.[0];

    if (!prompt || typeof prompt !== 'string' || prompt.trim().length === 0) {
      return res.status(400).json({ error: 'Missing required field: prompt' });
    }
    if (!imageFile) {
      return res.status(400).json({ error: 'Missing required field: image (JPEG)' });
    }

    totalCalls += 1;
    saveCallCount(totalCalls);

    const imageBase64 = imageFile.buffer.toString('base64');
    const startMs = Date.now();

    // Build content array: prepend reference image when present.
    let content;
    const referenceFile = req.files['reference']?.[0];
    if (referenceFile) {
      const refBase64 = referenceFile.buffer.toString('base64');
      content = [
        { type: 'text', text: 'Reference photo:' },
        { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: refBase64 } },
        { type: 'text', text: 'Current live view:' },
        { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: imageBase64 } },
        { type: 'text', text: prompt.trim() },
      ];
    } else {
      content = [
        { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: imageBase64 } },
        { type: 'text', text: prompt.trim() },
      ];
    }

    const message = await anthropic.messages.create({
      model: MODEL_ID,
      max_tokens: MAX_TOKENS,
      thinking: { type: 'disabled' },
      messages: [{ role: 'user', content }],
    });

    const result = message.content
      .filter((block) => block.type === 'text')
      .map((block) => block.text)
      .join('');

    const latencyMs = Date.now() - startMs;

    // Log metadata only — image bytes are NEVER logged
    console.log(
      JSON.stringify({
        ts: new Date().toISOString(),
        promptLen: prompt.length,
        responseLen: result.length,
        latencyMs,
        callNo: totalCalls,
        hasReference: Boolean(referenceFile),
      })
    );

    return res.json({ result });
  } catch (err) {
    console.error('[analyze error]', err?.message ?? String(err));

    if (err?.status === 429) {
      return res.status(429).json({ error: 'Upstream rate limit from Anthropic API.' });
    }
    return res.status(502).json({ error: 'VLM call failed', detail: err?.message ?? 'Unknown error' });
  }
});

// ── GET /health ────────────────────────────────────────────────────────────────
app.get('/health', (_req, res) => {
  res.json({
    status: 'ok',
    calls: totalCalls,
    ceiling: HARD_CALL_CEILING,
  });
});

// ── Start ──────────────────────────────────────────────────────────────────────
const apiKeyPresent = Boolean(process.env.ANTHROPIC_API_KEY);
if (!apiKeyPresent) {
  console.warn(
    '[picpal-proxy] WARNING: ANTHROPIC_API_KEY is not set. /analyze requests will fail.'
  );
}

app.listen(PORT, () => {
  console.log(
    `[picpal-proxy] Listening on http://localhost:${PORT}  (key present: ${apiKeyPresent})`
  );
});
