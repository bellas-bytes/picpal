import express from 'express';
import rateLimit from 'express-rate-limit';
import multer from 'multer';
import { buildAnalysis, validateResult } from './reference-analysis.js';
import { createCounter } from './resources.js';

export async function createApp({ upstream, counterPath, ceiling = 200, maxActive = 4, timeoutMs = 30_000 }) {
  if (!Number.isSafeInteger(maxActive) || maxActive < 1 || !Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error('Invalid resource limits');
  const counter = await createCounter({ path: counterPath, ceiling, maxPending: maxActive });
  const app = express();
  let activeRequests = 0;
  // Rejected partial bodies must not outlive the admission slot/deadline. Keep
  // successful and fully consumed requests eligible for HTTP keep-alive.
  app.use('/analyze', (req, res, next) => {
    res.once('finish', () => { if (res.statusCode >= 400 && !req.complete) req.destroy(); });
    next();
  });
  app.use('/analyze', rateLimit({ windowMs: 60_000, max: 20, standardHeaders: true, legacyHeaders: false,
    message: { error: 'Rate limit exceeded. Try again shortly.' } }));
  // Admission precedes multipart parsing. There is no waiting queue.
  app.use('/analyze', (req, res, next) => {
    if (activeRequests >= maxActive) return res.set('Retry-After', '1').status(503).json({ error: 'Proxy busy. Retry after one second.' });
    activeRequests++;
    const controller = new AbortController();
    req.analysisSignal = controller.signal;
    let released = false;
    const release = () => {
      if (released) return;
      released = true;
      activeRequests--;
      clearTimeout(timer);
      req.off('aborted', disconnected);
      res.off('close', disconnected);
      res.off('finish', release);
    };
    const disconnected = () => { controller.abort(new Error('Client disconnected')); release(); };
    // Covers slow/incomplete uploads as well as the upstream call.
    const timer = setTimeout(() => {
      controller.abort(new Error('Request timed out'));
      if (!res.headersSent && !res.destroyed) {
        // Close an unfinished upload after the timeout response is flushed.
        if (!req.complete) res.once('finish', () => req.destroy());
        res.status(504).json({ error: 'Analysis timed out. Try again.' });
      }
      release();
    }, timeoutMs);
    req.once('aborted', disconnected);
    res.once('close', disconnected);
    res.once('finish', release);
    next();
  });
  const upload = multer({ storage: multer.memoryStorage(),
    limits: { fileSize: 5 * 1024 * 1024, files: 2, fields: 3, fieldSize: 16000, parts: 5 },
    fileFilter: (_req, file, cb) => cb(file.mimetype === 'image/jpeg' || file.mimetype === 'image/jpg' ? null : new Error('JPEG required'), true),
  });
  app.post('/analyze', upload.fields([{ name: 'image', maxCount: 1 }, { name: 'reference', maxCount: 1 }]), async (req, res) => {
    const available = () => !req.analysisSignal.aborted && !res.destroyed && !res.writableEnded;
    if (!available()) return;
    let analysis;
    try { analysis = buildAnalysis(req.body, req.files); }
    catch { return res.status(400).json({ error: 'Invalid analysis request' }); }
    let callNo;
    try { callNo = await counter.reserve(); }
    catch { if (available()) res.status(503).json({ error: 'Persistent call budget unavailable. Operator action required; restarting does not reset it.' }); return; }
    if (!available()) return;
    try {
      const started = Date.now();
      const message = await upstream({ model: 'claude-sonnet-5', max_tokens: analysis.max_tokens,
        thinking: { type: 'disabled' }, messages: [{ role: 'user', content: analysis.content }] },
        { signal: req.analysisSignal, maxRetries: 0 });
      if (!available()) return;
      const result = message.content.filter(block => block.type === 'text').map(block => block.text).join('');
      if (message.stop_reason === 'max_tokens') throw new Error('Truncated response');
      validateResult(analysis.operation, result);
      console.log(JSON.stringify({ operation: analysis.operation, responseLen: result.length, latencyMs: Date.now() - started, callNo }));
      res.json({ result });
    } catch (error) {
      if (available()) res.status(error?.status === 429 ? 429 : 502).json({ error: 'VLM call failed' });
    }
  });
  app.use((error, _req, res, _next) => {
    if (!res.headersSent && !res.destroyed) res.status(400).json({ error: 'Invalid image upload' });
  });
  app.get('/health', (_req, res) => {
    const state = counter.snapshot();
    res.json({ status: state.healthy ? 'ok' : 'budget_unavailable', calls: state.totalCalls,
      ceiling: state.ceiling, remainingCalls: state.remainingCalls, activeRequests, maxActive });
  });
  return app;
}
