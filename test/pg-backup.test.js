import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import {
  assertSafeRestoreTarget,
  decryptArchiveFile,
  encryptArchiveFile,
  parseBackupKey,
} from '../server/pg-backup.mjs';

const key = Buffer.alloc(32, 7);
const encodedKey = key.toString('hex');

test('backup key must be exactly 32 bytes of hexadecimal material', () => {
  assert.equal(parseBackupKey(encodedKey).length, 32);
  assert.throws(() => parseBackupKey('short'), /64 hexadecimal/);
  assert.throws(() => parseBackupKey('z'.repeat(64)), /64 hexadecimal/);
});

test('restore requires an isolated _test database and explicit replacement', () => {
  const base = { sourceDatabase: 'ielts_accent_lab_test', replace: true };
  assert.doesNotThrow(() => assertSafeRestoreTarget({ ...base, targetDatabase: 'ielts_restore_test' }));
  assert.throws(() => assertSafeRestoreTarget({ ...base, targetDatabase: 'ielts_accent_lab' }), /end in _test/);
  assert.throws(() => assertSafeRestoreTarget({ ...base, targetDatabase: base.sourceDatabase }), /differ from the source/);
  assert.throws(() => assertSafeRestoreTarget({ ...base, targetDatabase: 'ielts_restore_test', replace: false }), /explicit --replace/);
});

test('encrypted snapshots round-trip, reject tampering, and refuse overwrite', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'hsk-pg-backup-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const source = join(directory, 'source.dump');
  const encrypted = join(directory, 'snapshot.pgbak');
  const restored = join(directory, 'restored.dump');
  await writeFile(source, Buffer.from('synthetic PostgreSQL custom archive payload'));

  await encryptArchiveFile(source, encrypted, {
    format: 1,
    project: 'ielts-accent-coach',
    database: 'ielts_accent_lab_test',
    createdAt: new Date(0).toISOString(),
  }, key);
  await assert.rejects(encryptArchiveFile(source, encrypted, {
    format: 1, project: 'ielts-accent-coach', database: 'ielts_accent_lab_test',
  }, key), { code: 'EEXIST' });

  const result = await decryptArchiveFile(encrypted, directory, key);
  try {
    assert.equal(result.metadata.database, 'ielts_accent_lab_test');
    await writeFile(restored, await readFile(result.archivePath));
    assert.deepEqual(await readFile(restored), await readFile(source));
  } finally {
    await rm(result.directory, { recursive: true, force: true });
  }

  const contents = await readFile(encrypted);
  contents[contents.length - 1] ^= 0x01;
  await writeFile(encrypted, contents);
  await assert.rejects(decryptArchiveFile(encrypted, directory, key), /authentication failed/i);
});

test('snapshot cannot be decrypted with another project identity', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'hsk-pg-backup-project-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const source = join(directory, 'source.dump');
  const encrypted = join(directory, 'snapshot.pgbak');
  await writeFile(source, 'synthetic archive');
  await encryptArchiveFile(source, encrypted, {
    format: 1, project: 'another-project', database: 'source_test',
  }, key);
  await assert.rejects(decryptArchiveFile(encrypted, directory, key), /another project/i);
});
