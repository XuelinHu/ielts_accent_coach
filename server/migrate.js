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
  await maintenanceClient.end();
}

const client = new Client({ ...baseConfig, database: databaseName });
await client.connect();
try {
  await client.query(`
    CREATE TABLE IF NOT EXISTS schema_migration (
      name VARCHAR(180) PRIMARY KEY,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);
  const files = (await readdir(directory))
    .filter((file) => /^\d+_[a-z0-9_]+\.sql$/.test(file))
    .sort();

  for (const file of files) {
    const applied = await client.query(
      'SELECT 1 FROM schema_migration WHERE name = $1',
      [file],
    );
    if (applied.rowCount > 0) {
      console.log(`Skipped ${file} (already applied).`);
      continue;
    }
    const sql = await readFile(path.join(directory, file), 'utf8');
    await client.query('BEGIN');
    try {
      await client.query(sql);
      await client.query('INSERT INTO schema_migration (name) VALUES ($1)', [file]);
      await client.query('COMMIT');
      console.log(`Applied ${file}.`);
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    }
  }
} finally {
  await client.end();
}

