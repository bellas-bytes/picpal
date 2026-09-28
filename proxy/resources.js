import { readFile, writeFile, rename, unlink } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';

// Single-process reservation ledger: persist BEFORE upstream dispatch. Reservations
// are conservative and never refunded, including cancellation after persistence.
export async function createCounter({ path, ceiling = 200, maxPending = 200 }) {
  if (!Number.isSafeInteger(ceiling) || ceiling < 1 || ceiling > 200) throw new Error('Invalid ceiling');
  if (!Number.isSafeInteger(maxPending) || maxPending < 1) throw new Error('Invalid persistence limit');
  let totalCalls = 0, healthy = true, pending = 0, tail = Promise.resolve();
  try {
    const parsed = JSON.parse(await readFile(path, 'utf8'));
    if (!Number.isSafeInteger(parsed.totalCalls) || parsed.totalCalls < 0) throw new Error('Invalid counter');
    totalCalls = parsed.totalCalls;
  } catch (error) {
    if (error.code !== 'ENOENT') healthy = false;
  }
  return {
    snapshot: () => ({ totalCalls, ceiling, remainingCalls: healthy ? Math.max(0, ceiling - totalCalls) : 0, healthy }),
    reserve() {
      // Deadlines may release HTTP admission while a filesystem write remains
      // stalled. Bound the persistence queue independently in that case.
      if (pending >= maxPending) return Promise.reject(new Error('Persistence busy'));
      pending++;
      const reservation = tail.then(async () => {
        if (!healthy || totalCalls >= ceiling) throw new Error('Quota unavailable');
        const next = totalCalls + 1;
        const temporary = `${path}.${randomUUID()}.tmp`;
        try {
          await writeFile(temporary, JSON.stringify({ totalCalls: next }), { flag: 'wx', mode: 0o600 });
          await rename(temporary, path);
          totalCalls = next;
          return next;
        } catch (error) {
          healthy = false;
          await unlink(temporary).catch(() => {});
          throw error;
        }
      });
      tail = reservation.then(() => { pending--; }, () => { pending--; });
      return reservation;
    },
  };
}
