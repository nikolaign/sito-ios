// SITO private encrypted archive. Bind a Cloudflare D1 database as ARCHIVE.
// Only ciphertext reaches this Worker; SITO_TOKEN is a Worker secret.

const MAX_OBJECT = 40 * 1024 * 1024;
const MAX_MANIFEST = 8 * 1024 * 1024;
const PART_BYTES = 1_000_000; // D1 limits each BLOB to 2,000,000 bytes.
const SOFT_STORAGE_LIMIT = 360_000_000; // Leave space for SQLite overhead/orphans.
const objectRoute = /^\/v1\/objects\/([a-f0-9]{64})$/;
const partRoute = /^\/v1\/objects\/([a-f0-9]{64})\/parts\/(0|[1-9][0-9]*)$/;
const commitRoute = /^\/v1\/objects\/([a-f0-9]{64})\/commit$/;

function reply(body, status = 200, extra = {}) {
  return new Response(body, {
    status,
    headers: {
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
      ...extra,
    },
  });
}

function tokenMatches(candidate, expected) {
  if (!candidate || !expected) return false;
  const a = new TextEncoder().encode(candidate);
  const b = new TextEncoder().encode(expected);
  let mismatch = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    mismatch |= (a[i] ?? 0) ^ (b[i] ?? 0);
  }
  return mismatch === 0;
}

async function verifiedBody(request, sizeLimit, expectedHash = null) {
  const declared = Number(request.headers.get('content-length') ?? 0);
  if (declared > sizeLimit) return null;
  const bytes = await request.arrayBuffer();
  if (!bytes.byteLength || bytes.byteLength > sizeLimit) return null;
  if (expectedHash) {
    const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))]
      .map((b) => b.toString(16).padStart(2, '0')).join('');
    if (hash !== expectedHash) return null;
  }
  return new Uint8Array(bytes);
}

async function metadata(db, key) {
  return db.prepare('SELECT byte_length, parts FROM objects WHERE object_key = ?')
    .bind(key).first();
}

async function storageAvailable(db, extraBytes) {
  const row = await db.prepare('SELECT COALESCE(SUM(byte_length), 0) AS used FROM objects').first();
  return Number(row?.used ?? 0) + extraBytes <= SOFT_STORAGE_LIMIT;
}

async function immutablePut(db, key, bytes) {
  if (await metadata(db, key)) return reply('Already stored', 200);
  if (!await storageAvailable(db, bytes.byteLength)) {
    return reply('Free D1 archive storage budget reached; keep local copies and free cloud space manually.', 507);
  }

  // Two BLOBs per batch keep memory bounded. The metadata row is inserted
  // LAST: an interrupted upload is never advertised as a complete object.
  // Retrying the same immutable object safely replaces incomplete parts.
  for (let offset = 0, part = 0; offset < bytes.byteLength; offset += PART_BYTES * 2, part += 2) {
    const batch = [];
    for (let i = 0; i < 2 && offset + i * PART_BYTES < bytes.byteLength; i++) {
      const begin = offset + i * PART_BYTES;
      batch.push(db.prepare('INSERT OR REPLACE INTO object_parts (object_key, part, data) VALUES (?, ?, ?)')
        .bind(key, part + i, bytes.subarray(begin, begin + PART_BYTES)));
    }
    await db.batch(batch);
  }
  const expectedParts = Math.ceil(bytes.byteLength / PART_BYTES);
  const check = await db.prepare('SELECT COUNT(*) AS count, COALESCE(SUM(LENGTH(data)), 0) AS total FROM object_parts WHERE object_key = ?')
    .bind(key).first();
  if (check?.count !== expectedParts || check?.total !== bytes.byteLength) {
    return reply('Incomplete upload; retry safely', 503);
  }
  await db.prepare('INSERT OR IGNORE INTO objects (object_key, byte_length, parts) VALUES (?, ?, ?)')
    .bind(key, bytes.byteLength, expectedParts).run();
  return reply('Stored', 201);
}

// Large PDFs use one HTTP request per BLOB. On Workers Free, spreading CPU
// across invocations is safer than parsing, hashing and saving 35 MB at once.
async function objectPart(db, key, part, request) {
  const maxParts = Math.ceil(MAX_OBJECT / PART_BYTES);
  if (part >= maxParts) return reply('Invalid part index', 400);
  if (request.method === 'GET') {
    if (!await metadata(db, key)) return reply('Not found', 404);
    const row = await db.prepare('SELECT data FROM object_parts WHERE object_key = ? AND part = ?')
      .bind(key, part).first();
    return row?.data ? reply(new Uint8Array(row.data), 200,
      { 'content-type': 'application/octet-stream' }) : reply('Not found', 404);
  }
  if (await metadata(db, key)) return reply('Immutable object already committed', 409);
  const bytes = await verifiedBody(request, PART_BYTES);
  if (!bytes) return reply('Invalid part size', 400);
  // Fail early before the database reaches the physical quota.
  if (!await storageAvailable(db, bytes.byteLength)) return reply('Free archive storage budget reached', 507);
  await db.prepare('INSERT OR REPLACE INTO object_parts (object_key, part, data) VALUES (?, ?, ?)')
    .bind(key, part, bytes).run();
  return reply('Part stored', 201);
}

async function objectCommit(db, key, request) {
  if (await metadata(db, key)) return reply('Already stored', 200);
  const raw = await verifiedBody(request, 128);
  if (!raw) return reply('Invalid commit', 400);
  let size;
  try { size = JSON.parse(new TextDecoder().decode(raw)).byteLength; } catch { return reply('Invalid commit', 400); }
  if (!Number.isSafeInteger(size) || size < 1 || size > MAX_OBJECT) return reply('Invalid length', 400);
  if (!await storageAvailable(db, size)) return reply('Free archive storage budget reached', 507);
  const expected = Math.ceil(size / PART_BYTES);
  const check = await db.prepare('SELECT COUNT(*) AS count, COALESCE(SUM(LENGTH(data)), 0) AS total, MIN(part) AS first, MAX(part) AS last FROM object_parts WHERE object_key = ?')
    .bind(key).first();
  if (check?.count !== expected || check?.total !== size ||
      check?.first !== 0 || check?.last !== expected - 1) return reply('Incomplete encrypted object', 409);
  await db.prepare('INSERT OR IGNORE INTO objects (object_key, byte_length, parts) VALUES (?, ?, ?)')
    .bind(key, size, expected).run();
  return reply('Committed', 201);
}

function partStatements(db, key, bytes) {
  const result = [];
  for (let offset = 0, part = 0; offset < bytes.byteLength; offset += PART_BYTES, part++) {
    result.push(db.prepare('INSERT INTO object_parts (object_key, part, data) VALUES (?, ?, ?)')
      .bind(key, part, bytes.subarray(offset, offset + PART_BYTES)));
  }
  return result;
}

async function manifestPut(db, bytes) {
  const old = await metadata(db, 'manifest/latest');
  // The old latest becomes previous; the former previous is overwritten.
  // This conservatively budgets the whole new manifest for SQLite slack.
  if (!await storageAvailable(db, bytes.byteLength)) {
    return reply('Free D1 archive storage budget reached; existing manifest preserved.', 507);
  }

  // A single D1 batch is transactional. Readers see either the old latest
  // or the new latest, never a partially-written encrypted manifest.
  const statements = [
    db.prepare("DELETE FROM object_parts WHERE object_key = 'manifest/previous'"),
    db.prepare("DELETE FROM objects WHERE object_key = 'manifest/previous'"),
    db.prepare("INSERT INTO object_parts (object_key, part, data) SELECT 'manifest/previous', part, data FROM object_parts WHERE object_key = 'manifest/latest'"),
    db.prepare("INSERT INTO objects (object_key, byte_length, parts) SELECT 'manifest/previous', byte_length, parts FROM objects WHERE object_key = 'manifest/latest'"),
    db.prepare("DELETE FROM object_parts WHERE object_key = 'manifest/latest'"),
    db.prepare("DELETE FROM objects WHERE object_key = 'manifest/latest'"),
    ...partStatements(db, 'manifest/latest', bytes),
    db.prepare('INSERT INTO objects (object_key, byte_length, parts) VALUES (?, ?, ?)')
      .bind('manifest/latest', bytes.byteLength, Math.ceil(bytes.byteLength / PART_BYTES)),
  ];
  await db.batch(statements);
  return reply('Committed', 201);
}

async function objectGet(db, key, method) {
  const meta = await metadata(db, key);
  if (!meta) return reply(method === 'HEAD' ? null : 'Not found', 404);
  if (method === 'HEAD') return reply(null, 200, {
    'content-length': String(meta.byte_length),
    'x-sito-parts': String(meta.parts),
  });

  let part = 0;
  const body = new ReadableStream({
    async pull(controller) {
      if (part >= meta.parts) { controller.close(); return; }
      try {
        const row = await db.prepare('SELECT data FROM object_parts WHERE object_key = ? AND part = ?')
          .bind(key, part++).first();
        if (!row?.data) throw new Error('Archive chunk missing');
        controller.enqueue(new Uint8Array(row.data));
      } catch (error) { controller.error(error); }
    },
  });
  return reply(body, 200, { 'content-type': 'application/octet-stream',
    'content-length': String(meta.byte_length) });
}

export default {
  async fetch(request, env) {
    if (!env.SITO_TOKEN || !env.ARCHIVE) return reply('Vault not configured', 503);
    if (!tokenMatches(request.headers.get('authorization')?.replace(/^Bearer /i, ''), env.SITO_TOKEN)) {
      return reply('Unauthorized', 401);
    }

    const url = new URL(request.url);
    const match = url.pathname.match(objectRoute);
    const partMatch = url.pathname.match(partRoute);
    const commitMatch = url.pathname.match(commitRoute);
    const isManifest = url.pathname === '/v1/manifest';
    const isPrevious = url.pathname === '/v1/manifest/previous';
    if (url.search || (!match && !partMatch && !commitMatch && !isManifest && !isPrevious)) {
      return reply('Not found', 404);
    }
    if (!['GET', 'HEAD', 'PUT'].includes(request.method)) return reply('Method not allowed', 405);
    if (isPrevious && request.method === 'PUT') return reply('Read only', 405);
    if (partMatch && !['GET', 'PUT'].includes(request.method)) return reply('Method not allowed', 405);
    if (commitMatch && request.method !== 'PUT') return reply('Method not allowed', 405);

    try {
      if (partMatch) return await objectPart(env.ARCHIVE, 'objects/' + partMatch[1],
        Number(partMatch[2]), request);
      if (commitMatch) return await objectCommit(env.ARCHIVE, 'objects/' + commitMatch[1], request);
      const key = isManifest ? 'manifest/latest' : isPrevious ? 'manifest/previous' : 'objects/' + match[1];
      if (request.method === 'HEAD' || request.method === 'GET') {
        return await objectGet(env.ARCHIVE, key, request.method);
      }
      const bytes = await verifiedBody(request, isManifest ? MAX_MANIFEST : MAX_OBJECT,
        match ? match[1] : null);
      if (!bytes) return reply('Invalid body, size, or checksum', 400);
      return isManifest ? await manifestPut(env.ARCHIVE, bytes)
        : await immutablePut(env.ARCHIVE, key, bytes);
    } catch (error) {
      console.error('Private archive operation failed', error);
      return reply('Archive database unavailable or free quota exceeded. Existing backups were not deleted.', 503);
    }
  },
};
