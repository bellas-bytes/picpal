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

// ── Named constants ────────────────────────────────────────────────────────────
const PORT                 = 4000;
const MODEL_ID             = 'claude-sonnet-5';
const MAX_TOKENS           = 64;    // ≤15-word reply ≈ 20 tokens; 64 gives headroom
const RATE_LIMIT_WINDOW_MS = 60_000;   // 1 minute per rolling window
const RATE_LIMIT_MAX_CALLS = 20;       // max calls per IP per window
const HARD_CALL_CEILING    = 200;      // total calls this process lifetime
const MAX_IMAGE_BYTES      = 5 * 1024 * 1024; // 5 MB per upload

// ── Global call counter ────────────────────────────────────────────────────────
let totalCalls = 0;

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
app.post('/analyze', upload.single('image'), async (req, res) => {
  try {
    // Hard call ceiling — enforced server-side, independent of client-side gate
    if (totalCalls >= HARD_CALL_CEILING) {
      return res
        .status(503)
        .json({ error: 'Hard call ceiling reached. Restart the proxy to reset.' });
    }

    const { prompt } = req.body;
    const image = req.file;

    if (!prompt || typeof prompt !== 'string' || prompt.trim().length === 0) {
      return res.status(400).json({ error: 'Missing required field: prompt' });
    }
    if (!image) {
      return res.status(400).json({ error: 'Missing required field: image (JPEG)' });
    }

    totalCalls += 1;

    const imageBase64 = image.buffer.toString('base64');
    const startMs = Date.now();

    const message = await anthropic.messages.create({
      model: MODEL_ID,
      max_tokens: MAX_TOKENS,
      thinking: { type: 'disabled' },
      messages: [
        {
          role: 'user',
          content: [
            {
              type: 'image',
              source: { type: 'base64', media_type: 'image/jpeg', data: imageBase64 },
            },
            { type: 'text', text: prompt.trim() },
          ],
        },
      ],
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
    totalCalls,
    callsRemaining: HARD_CALL_CEILING - totalCalls,
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
