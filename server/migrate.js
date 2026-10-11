import { createHash } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const { Client } = pg;
const directory = path.join(path.dirname(fileURLToPath(import.meta.url)), 'migrations');
const databaseName = process.env.DB_NAME?.trim() ?? 'ielts_accent_lab';

if (!/^[a-z][a-z0-9_]{0,62}$/.test(databaseName)) {
  throw new Error('DB_NAME must be a safe lowercase PostgreSQL identifier.');
}

const baseConfig = {
  host: process.env.DB_HOST,
  port: Number.parseInt(process.env.DB_PORT ?? '5432', 10),
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : false,
  connectionTimeoutMillis: 5_000,
};

const maintenanceClient = new Client({ ...baseConfig, database: 'postgres' });
await maintenanceClient.connect();
try {
  await maintenanceClient.query(
    "SELECT pg_advisory_lock(hashtext('ielts-accent-coach:database-create'))",
  );
  const existing = await maintenanceClient.query(
    'SELECT 1 FROM pg_database WHERE datname = $1',
    [databaseName],
  );
  if (existing.rowCount === 0) {
    await maintenanceClient.query(`CREATE DATABASE "${databaseName}"`);
    console.log(`Created database ${databaseName}.`);
  } else {
    console.log(`Database ${databaseName} already exists.`);
  }
} finally {
  await maintenanceClient.query(
    "SELECT pg_advisory_unlock(hashtext('ielts-accent-coach:database-create'))",
  ).catch(() => {});
  await maintenanceClient.end();
}

const client = new Client({ ...baseConfig, database: databaseName });
await client.connect();
try {
  await client.query('BEGIN');
  await client.query(
    "SELECT pg_advisory_xact_lock(hashtext('ielts-accent-coach:migrations'))",
  );
  await client.query(`
    CREATE TABLE IF NOT EXISTS schema_migration (
      name VARCHAR(180) PRIMARY KEY,
      checksum CHAR(64),
      applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);
  await client.query(
    'ALTER TABLE schema_migration ADD COLUMN IF NOT EXISTS checksum CHAR(64)',
  );
  const files = (await readdir(directory))
    .filter((file) => /^\d+_[a-z0-9_]+\.sql$/.test(file))
    .sort();

  for (const file of files) {
    const sql = await readFile(path.join(directory, file), 'utf8');
    const checksum = createHash('sha256').update(sql).digest('hex');
    const applied = await client.query(
      'SELECT checksum FROM schema_migration WHERE name = $1',
      [file],
    );
    if (applied.rowCount > 0) {
      const recordedChecksum = applied.rows[0].checksum?.trim();
      if (recordedChecksum && recordedChecksum !== checksum) {
        throw new Error(`Applied migration was modified: ${file}`);
      }
      if (!recordedChecksum) {
        await client.query(
          'UPDATE schema_migration SET checksum = $2 WHERE name = $1',
          [file, checksum],
        );
        console.log(`Recorded checksum for legacy migration ${file}.`);
      }
      console.log(`Skipped ${file} (already applied).`);
      continue;
    }
    await client.query(sql);
    await client.query(
      'INSERT INTO schema_migration (name, checksum) VALUES ($1, $2)',
      [file, checksum],
    );
    console.log(`Applied ${file}.`);
  }
  await client.query('COMMIT');
} catch (error) {
  await client.query('ROLLBACK').catch(() => {});
  throw error;
} finally {
  await client.end();
}
