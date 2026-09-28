# Development proxy

Run `npm install`, set `ANTHROPIC_API_KEY`, then `npm start`. The listener defaults to
0.0.0.0:4000, preserving physical-iPhone development through the Mac's LAN IP.
Set `HOST=127.0.0.1` for simulator-only access. This is a single-process
development service, not a public authenticated API.

`POST /analyze` accepts the existing JPEG multipart contract. Four requests may
be active globally, including uploads. Admission happens before multipart memory
allocation; excess work returns 503 with `Retry-After: 1`, without a queue. The
per-IP 20/minute limiter and 5 MB/file (two files maximum) limits remain. A
30-second total request deadline covers uploads, persistence, and upstream work.
Timeout returns 504 and aborts the SDK request; disconnect also aborts it. SDK
retries are disabled. Cancellation cannot undo work already accepted by the
upstream provider, so reserved budget is never refunded.

The persistent **200-call ceiling does not reset on restart**. Valid requests
reserve budget through a serialized asynchronous write and atomic rename before
calling the provider. A missing ledger starts at zero; corrupt/unreadable data or
write failure closes admission to upstream calls. To deliberately reset the
budget, stop the sole proxy process, review incurred usage, then replace
`proxy/.call-counter.json` with `{"totalCalls":0}` and restart. Never reset while
running. Back up a damaged ledger and restore a known conservative count instead
of discarding it. Reservations can be consumed without a provider call if the
client disconnects after persistence or the process crashes before dispatch.

`GET /health` reports `status`, `calls`, `ceiling`, `remainingCalls`,
`activeRequests`, and `maxActive`. `budget_unavailable` means operator repair is
required. A healthy ledger with zero remaining calls still reports `ok` and zero
remaining budget. No keys, prompts, or image bytes appear in these metrics.

Run `node --test proxy/test/*.test.js evals/reference-coaching/evaluate.test.mjs`
from the repository root. HTTP regression tests bind ephemeral localhost ports
and mock the provider; they do not spend API credit. App construction is exported
from `app.js` and does not start a listener or construct an SDK client.

Limits: atomic replacement protects against partial JSON writes, but this is not
a cross-process ledger or a power-loss durable database (no fsync). Run one
process per ledger and do not share it across instances. Four admitted uploads
bound retained multipart payloads to roughly 40 MB plus encoding/SDK overhead;
this is not a measured RSS guarantee. Physical-device, real-provider latency,
and public-hosting authentication/load tests remain follow-up work.
