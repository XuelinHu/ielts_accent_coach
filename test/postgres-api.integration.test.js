import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { createServer as createNetServer } from 'node:net';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test, { after } from 'node:test';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const requireServerDependency = createRequire(path.join(projectRoot, 'server', 'package.json'));
const pg = requireServerDependency('pg');
const integrationEnabled = process.env.RUN_POSTGRES_INTEGRATION === '1';
let apiProcess;
let mockProvider;

after(async () => {
  if (apiProcess && apiProcess.exitCode === null) {
    apiProcess.kill('SIGTERM');
    await Promise.race([once(apiProcess, 'exit'), delay(3000)]);
  }
  if (mockProvider?.listening) {
    mockProvider.close();
    await once(mockProvider, 'close');
  }
});

test('PostgreSQL API isolates users, pages attempts, and persists AI exchanges', {
  skip: !integrationEnabled,
  timeout: 60_000,
}, async () => {
  assert.match(process.env.DB_NAME || '', /_test$/, 'refusing to run outside a _test database');
  assert.ok(process.env.DB_PASSWORD, 'DB_PASSWORD must be configured');

  const migrations = await Promise.all([runMigration(), runMigration()]);
  assert.equal(migrations.length, 2);
  assert.ok(migrations.every((result) => result.code === 0), migrations.map((result) => result.output).join('\n'));
  await verifyMigrationDriftIsRejected();

  const providerCalls = [];
  mockProvider = createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = Buffer.concat(chunks).toString('utf8');
    providerCalls.push({ authorization: request.headers.authorization, body });
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({
      choices: [{ message: { content: body.includes('input_audio')
        ? 'The train arrives at nine.'
        : 'Focus on linking sounds.' } }],
    }));
  });
  mockProvider.listen(0, '127.0.0.1');
  await once(mockProvider, 'listening');

  const port = await freePort();
  const baseUrl = `http://127.0.0.1:${port}`;
  const providerUrl = `http://127.0.0.1:${mockProvider.address().port}/v1/chat/completions`;
  apiProcess = spawn(process.execPath, ['server.js'], {
    cwd: path.join(projectRoot, 'server'),
    env: {
      ...process.env,
      PORT: String(port),
      AI_BASE_URL: providerUrl,
      AI_API_KEY: 'integration-only-key',
      AI_MODEL: 'integration-chat',
      DASHSCOPE_API_URL: providerUrl,
      DASHSCOPE_API_KEY: 'integration-only-key',
      DASHSCOPE_ASR_MODEL: 'integration-asr',
    },
    stdio: 'ignore',
  });

  await waitForApi(baseUrl);
  const health = await getJson(`${baseUrl}/api/health`);
  assert.equal(health.database.connected, true);
  assert.equal(health.provider, 'LAN OpenAI-compatible API');
  assert.equal(JSON.stringify(health).includes('integration-only-key'), false);

  const suffix = `${Date.now()}${Math.floor(Math.random() * 1000)}`;
  const firstUserResult = await postJson(`${baseUrl}/api/users/ensure`, {
    installationId: `integration-${suffix}-a`,
    deviceModel: 'integration-test-device',
    appVersion: 'test',
  });
  const secondUserResult = await postJson(`${baseUrl}/api/users/ensure`, {
    installationId: `integration-${suffix}-b`,
  });
  assert.equal(firstUserResult.status, 200);
  assert.equal(secondUserResult.status, 200);
  const firstUser = firstUserResult.body;
  const secondUser = secondUserResult.body;
  assert.ok(firstUser.userId && firstUser.sessionId);
  assert.ok(secondUser.userId && secondUser.sessionId);
  assert.notEqual(firstUser.userId, secondUser.userId);

  const attemptIds = [];
  for (let index = 0; index < 3; index += 1) {
    const attempt = await postJson(`${baseUrl}/api/practice-attempts`, {
      userId: firstUser.userId,
      sessionId: firstUser.sessionId,
      accent: 'british',
      topic: 'Daily routine',
      level: 'Part 1',
      reference: 'I usually take the train.',
      transcript: `I usually take the train ${index}.`,
      focus: 'linking sounds',
      overall: 80 + index,
      accuracy: 82,
      completeness: 88,
      fluency: 78,
      requirements: ['Link usually and take.'],
      createdAt: new Date(Date.now() + index * 1000).toISOString(),
    });
    assert.equal(attempt.status, 201);
    attemptIds.push(attempt.body.id);
  }

  const pageOne = await getJson(
    `${baseUrl}/api/practice-attempts?userId=${firstUser.userId}&page=1&pageSize=2`,
  );
  const pageTwo = await getJson(
    `${baseUrl}/api/practice-attempts?userId=${firstUser.userId}&page=2&pageSize=2`,
  );
  const otherUserPage = await getJson(
    `${baseUrl}/api/practice-attempts?userId=${secondUser.userId}&page=1&pageSize=2`,
  );
  assert.equal(pageOne.total, 3);
  assert.equal(pageOne.attempts.length, 2);
  assert.equal(pageTwo.page, 2);
  assert.equal(pageTwo.attempts.length, 1);
  assert.equal(otherUserPage.total, 0);
  assert.equal(otherUserPage.attempts.length, 0);

  const audio = Buffer.alloc(1024, 1).toString('base64');
  const transcription = await postJson(`${baseUrl}/api/transcribe`, {
    audio: `data:audio/wav;base64,${audio}`,
    locale: 'en-GB',
  });
  assert.equal(transcription.body.transcript, 'The train arrives at nine.');

  const coachResult = await postJson(`${baseUrl}/api/coach`, {
    userId: firstUser.userId,
    sessionId: firstUser.sessionId,
    practiceAttemptId: attemptIds[0],
    message: 'How can I improve this answer?',
    history: [{ role: 'user', content: 'Give me one speaking tip.' }],
    practiceContext: { accent: 'british', overall: 80, transcript: 'I usually take the train.' },
  });
  assert.equal(coachResult.status, 200);
  const coach = coachResult.body;
  assert.equal(coach.reply, 'Focus on linking sounds.');
  assert.equal(coach.persisted, true);
  assert.ok(coach.conversationId);
  assert.equal(providerCalls.length, 2);
  assert.ok(providerCalls.every((call) => call.authorization === 'Bearer integration-only-key'));

  const client = new pg.Client({
    host: process.env.DB_HOST,
    port: Number.parseInt(process.env.DB_PORT ?? '5432', 10),
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    database: process.env.DB_NAME,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : false,
  });
  await client.connect();
  try {
    const migration = await client.query(
      "SELECT checksum FROM schema_migration WHERE name = '001_initial_schema.sql'",
    );
    assert.match(migration.rows[0]?.checksum?.trim() ?? '', /^[a-f0-9]{64}$/);
    const conversation = await client.query(
      'SELECT user_id, session_id FROM ai_conversation WHERE id = $1',
      [coach.conversationId],
    );
    const messages = await client.query(
      'SELECT role, content FROM ai_message WHERE conversation_id = $1 ORDER BY created_at, id',
      [coach.conversationId],
    );
    assert.equal(conversation.rows[0].user_id, firstUser.userId);
    assert.equal(conversation.rows[0].session_id, firstUser.sessionId);
    assert.deepEqual(new Set(messages.rows.map((row) => row.role)), new Set(['user', 'assistant']));
    assert.equal(messages.rows.find((row) => row.role === 'assistant').content, coach.reply);
  } finally {
    await client.end();
  }
});

async function freePort() {
  const server = createNetServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address();
  server.close();
  await once(server, 'close');
  return port;
}

async function runMigration() {
  const child = spawn(process.execPath, ['migrate.js'], {
    cwd: path.join(projectRoot, 'server'),
    env: process.env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  child.stdout.setEncoding('utf8').on('data', (chunk) => { output += chunk; });
  child.stderr.setEncoding('utf8').on('data', (chunk) => { output += chunk; });
  const [code] = await once(child, 'exit');
  return { code, output };
}

async function verifyMigrationDriftIsRejected() {
  const client = new pg.Client({
    host: process.env.DB_HOST,
    port: Number.parseInt(process.env.DB_PORT ?? '5432', 10),
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    database: process.env.DB_NAME,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : false,
  });
  await client.connect();
  try {
    const result = await client.query(
      "SELECT checksum FROM schema_migration WHERE name = '001_initial_schema.sql'",
    );
    const checksum = result.rows[0]?.checksum?.trim();
    assert.match(checksum ?? '', /^[a-f0-9]{64}$/);
    await client.query(
      "UPDATE schema_migration SET checksum = $1 WHERE name = '001_initial_schema.sql'",
      ['0'.repeat(64)],
    );
    try {
      const drift = await runMigration();
      assert.notEqual(drift.code, 0);
      assert.match(drift.output, /Applied migration was modified/);
    } finally {
      await client.query(
        "UPDATE schema_migration SET checksum = $1 WHERE name = '001_initial_schema.sql'",
        [checksum],
      );
    }
  } finally {
    await client.end();
  }
}

async function waitForApi(baseUrl) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (apiProcess.exitCode !== null) throw new Error(`API exited with code ${apiProcess.exitCode}`);
    try {
      const response = await fetch(`${baseUrl}/api/health`, { signal: AbortSignal.timeout(1000) });
      if (response.ok) return;
    } catch {
      await delay(100);
    }
  }
  throw new Error('API did not become ready within 10 seconds');
}

async function getJson(url) {
  const response = await fetch(url);
  assert.equal(response.status, 200);
  return response.json();
}

async function postJson(url, body) {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: response.status, body: await response.json() };
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
