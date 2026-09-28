/** Local development only: single process, persistent 200-call safety ceiling. */
import Anthropic from '@anthropic-ai/sdk';
import { fileURLToPath } from 'node:url';
import { createApp } from './app.js';

const anthropic = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY, maxRetries: 0 });
const app = await createApp({
  counterPath: fileURLToPath(new URL('.call-counter.json', import.meta.url)),
  upstream: (params, options) => anthropic.messages.create(params, options),
});
const host = process.env.HOST || '0.0.0.0';
app.listen(4000, host, () => {
  console.log(`[picpal-proxy] Listening on http://${host}:4000`);
});
