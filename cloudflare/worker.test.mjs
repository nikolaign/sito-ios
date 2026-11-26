import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import worker from './worker.mjs';

// Emulates the D1 statement/batch API with real SQLite, so schema, binding,
// transactional manifest rotation, and BLOB reads get exercised together.
class MemoryD1 {
  constructor() {
    this.sqlite = new DatabaseSync(':memory:');
    this.sqlite.exec(readFileSync(new URL('./schema.sql', import.meta.url), 'utf8'));
    this.failNextBatch = false;
  }

  prepare(sql) {
    const db = this.sqlite;
    const statement = { sql, args: [] };
    statement.bind = (...args) => { statement.args = args; return statement; };
    statement.first = async () => {
      const row = db.prepare(sql).get(...statement.args);
      if (!row) return null;
      if (row.data instanceof Uint8Array) row.data = [...row.data]; // D1 returns number[]
      return row;
    };
    statement.run = async () => db.prepare(sql).run(...statement.args);
    return statement;
  }

  async batch(statements) {
    this.sqlite.exec('BEGIN');
    try {
      for (const statement of statements) {
        if (this.failNextBatch) {
          this.failNextBatch = false;
          throw new Error('simulated database failure');
        }
        this.sqlite.prepare(statement.sql).run(...statement.args);
      }
      this.sqlite.exec('COMMIT');
    } catch (error) {
      this.sqlite.exec('ROLLBACK');
      throw error;
    }
  }
}

function setup() {
  const env = { SITO_TOKEN: 'sito-test-secret-that-is-not-deployed', ARCHIVE: new MemoryD1() };
  const call = (path, method = 'GET', body, token = env.SITO_TOKEN) => worker.fetch(
    new Request('https://example.workers.dev' + path, {
      method,
      headers: token ? { Authorization: `Bearer ${token}` } : {},
      ...(body ? { body } : {}),
    }), env);
  return { env, call };
}

test('rejects unauthenticated access, listing and unsupported methods', async () => {
  const { call } = setup();
  assert.equal((await call('/v1/manifest', 'GET', undefined, '')).status, 401);
  assert.equal((await call('/v1/objects', 'GET')).status, 404);
  assert.equal((await call('/v1/manifest', 'DELETE')).status, 405);
  assert.equal((await call('/v1/manifest?q=anything')).status, 404);
  assert.equal((await call('/v1/manifest')).status, 404);
});

test('stores, verifies, streams and reuses immutable encrypted objects', async () => {
  const { env, call } = setup();
  const payload = new TextEncoder().encode('already encrypted on device');
  const hash = createHash('sha256').update(payload).digest('hex');
  const path = '/v1/objects/' + hash;
  assert.equal((await call(path, 'PUT', payload)).status, 201);
  assert.equal((await call(path, 'HEAD')).status, 200);
  assert.equal(new TextDecoder().decode(await (await call(path)).arrayBuffer()), 'already encrypted on device');
  assert.equal((await call(path, 'PUT', payload)).status, 200);
  assert.equal((await call('/v1/objects/' + 'a'.repeat(64), 'PUT', payload)).status, 400);
  assert.equal(env.ARCHIVE.sqlite.prepare('SELECT COUNT(*) AS n FROM objects').get().n, 1);
});

test('a multi-MB saved PDF survives D1 BLOB chunking without alteration', async () => {
  const { env, call } = setup();
  const pdfCiphertext = randomBytes(2_400_121);
  const hash = createHash('sha256').update(pdfCiphertext).digest('hex');
  const path = '/v1/objects/' + hash;
  assert.equal((await call(path, 'PUT', pdfCiphertext)).status, 201);
  assert.equal(env.ARCHIVE.sqlite.prepare('SELECT parts FROM objects WHERE object_key=?')
    .get('objects/' + hash).parts, 3);
  const response = await call(path);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-length'), String(pdfCiphertext.byteLength));
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), pdfCiphertext);
});

test('large encrypted PDFs can be uploaded and downloaded one request per BLOB', async () => {
  const { env, call } = setup();
  const ciphertext = randomBytes(2_350_000);
  const hash = createHash('sha256').update(ciphertext).digest('hex');
  const path = '/v1/objects/' + hash;
  assert.equal((await call(path, 'HEAD')).status, 404);
  for (let start = 0, part = 0; start < ciphertext.length; start += 1_000_000, part++) {
    assert.equal((await call(path + '/parts/' + part, 'PUT',
      ciphertext.subarray(start, start + 1_000_000))).status, 201);
  }
  assert.equal((await call(path)).status, 404); // Partial uploads are private and invisible.
  assert.equal((await call(path + '/commit', 'PUT', JSON.stringify({ byteLength: 999 }))).status, 409);
  assert.equal((await call(path + '/commit', 'PUT',
    JSON.stringify({ byteLength: ciphertext.length }))).status, 201);
  const head = await call(path, 'HEAD');
  assert.equal(head.status, 200);
  assert.equal(head.headers.get('x-sito-parts'), '3');
  const pieces = [];
  for (let part = 0; part < 3; part++) {
    const response = await call(path + '/parts/' + part);
    assert.equal(response.status, 200);
    pieces.push(Buffer.from(await response.arrayBuffer()));
  }
  const restored = Buffer.concat(pieces);
  assert.deepEqual(restored, ciphertext);
  assert.equal(createHash('sha256').update(restored).digest('hex'), hash);
  assert.equal((await call(path + '/parts/0', 'PUT', ciphertext.subarray(0, 100))).status, 409);
  assert.equal(env.ARCHIVE.sqlite.prepare('SELECT parts FROM objects WHERE object_key = ?')
    .get('objects/' + hash).parts, 3);
});

test('manifest rotation is atomic and preserves the previous version', async () => {
  const { env, call } = setup();
  assert.equal((await call('/v1/manifest', 'PUT', 'ciphertext-v1')).status, 201);
  assert.equal((await call('/v1/manifest', 'PUT', 'ciphertext-v2')).status, 201);
  assert.equal(await (await call('/v1/manifest')).text(), 'ciphertext-v2');
  assert.equal(await (await call('/v1/manifest/previous')).text(), 'ciphertext-v1');
  assert.equal((await call('/v1/manifest/previous', 'PUT', 'not allowed')).status, 405);

  const oldError = console.error;
  console.error = () => {}; // Expected simulated failure should not spam the test output.
  try {
    env.ARCHIVE.failNextBatch = true;
    assert.equal((await call('/v1/manifest', 'PUT', 'ciphertext-v3')).status, 503);
  } finally {
    console.error = oldError;
  }
  assert.equal(await (await call('/v1/manifest')).text(), 'ciphertext-v2');
  assert.equal(await (await call('/v1/manifest/previous')).text(), 'ciphertext-v1');
});

test('the free-tier soft cap refuses new blobs while existing backups remain readable', async () => {
  const { env, call } = setup();
  env.ARCHIVE.sqlite.prepare('INSERT INTO objects (object_key,byte_length,parts) VALUES (?,?,?)')
    .run('filler', 359_999_990, 1);
  const payload = new TextEncoder().encode('ciphertext that does not fit');
  const hash = createHash('sha256').update(payload).digest('hex');
  assert.equal((await call('/v1/objects/' + hash, 'PUT', payload)).status, 507);
  assert.equal((await call('/v1/objects/' + hash)).status, 404);
});
