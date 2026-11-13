# Proposed fix: move idempotency into the database

**Status:** Not applied. Blocking condition for Friday.
**Owner needed:** relay service owners (changes how the API answers clients).

## Problem

Duplicate detection uses an in-memory `Map` (`seen` in `app/src/server.js`). That causes two failures.

1. **Retries get 500 instead of 409.** The map is private to each pod and is emptied on every
   restart. A retry that lands on another pod, or arrives after a restart, misses the map. The
   insert then hits the unique index, and the error handler turns it into a 500. HANDOFF.md says
   a 409 on replay is "expected and correct".
2. **Memory grows until the pod is killed.** `DEDUPE_MAX_ENTRIES` defaults to 0 (no limit), and
   every entry keeps the full payload (up to 8 KB), even though the 409 response only uses the id.

## Evidence

- **1 pod, 150 req/s, 5 min:** memory climbed ~1.3 to 1.4Mi/s to the 256Mi limit in ~2.5 min,
  the liveness probe killed the pod, and the restarted pod returned 500 to replays:
  `duplicate key value violates unique constraint "events_idempotency_key"`.
  Memory stayed at ~190Mi with no traffic afterwards.
- **2 pods, 150 req/s, 60 s, no restarts:** 177 of ~460 replays (~38%) returned 500.
  177 matching "duplicate key" lines in the logs.
  `total: sent=8997 status[201:8537 409:283 500:177] errors[-] p50=11ms p95=19ms p99=26ms`

## Why infrastructure cannot fix this

| Option | Result |
|---|---|
| Raise the memory limit | Delays the crash. Still 500s after restarts. |
| Set `DEDUPE_MAX_ENTRIES` | Bounds memory. Still 500s after restarts and across pods. |
| Pin to 1 replica | No 500s across pods, but no redundancy, and still 500s after every restart or deploy. |

No Kubernetes setting changes what the app returns on a duplicate.

## Proposed change

Remove the `seen` map and let Postgres's existing unique index decide. A duplicate is a normal
outcome, not an error.

```diff
-// Clients retry with the same Idempotency-Key. Replays are answered from
-// memory so a retry storm never reaches the database.
-const seen = new Map();
-
-function remember(key, entry) {
-  seen.set(key, entry);
-  if (config.dedupeMaxEntries > 0 && seen.size > config.dedupeMaxEntries) {
-    seen.delete(seen.keys().next().value);
-  }
-}
```

```diff
   if (!key) {
     return res.status(400).json({ error: 'Idempotency-Key header is required' });
   }
 
-  const previous = seen.get(key);
-  if (previous) {
-    return res.status(409).json({ id: previous.id, duplicate: true });
-  }
-
   const id = crypto.randomUUID();
   ...
   try {
-    await pool.query(
-      'INSERT INTO events (id, idempotency_key, payload, signature) VALUES ($1, $2, $3, $4)',
-      [id, key, payload, signature],
-    );
-    remember(key, { id, payload, signature });
+    const inserted = await pool.query(
+      `INSERT INTO events (id, idempotency_key, payload, signature)
+       VALUES ($1, $2, $3, $4)
+       ON CONFLICT (idempotency_key) DO NOTHING
+       RETURNING id`,
+      [id, key, payload, signature],
+    );
+    if (inserted.rowCount === 0) {
+      const { rows } = await pool.query(
+        'SELECT id FROM events WHERE idempotency_key = $1',
+        [key],
+      );
+      return res.status(409).json({ id: rows[0].id, duplicate: true });
+    }
     await archive(id, payload);
     res.status(201).json({ id, signature });
```

**What stays the same:** the API, the response bodies (201 `{id, signature}`, 409 `{id, duplicate: true}`),
and the database schema.

**Why this is safe across pods and restarts:** the unique index guarantees exactly one insert wins
for a key, even when two pods try at the same moment. Every other request gets 409 with the winner's id.