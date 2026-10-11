import { randomUUID } from 'node:crypto';
import pg from 'pg';
import { pageMetadata } from './pagination.js';

const { Pool } = pg;

export const databaseConfigured = Boolean(
  process.env.DB_HOST && process.env.DB_USER && process.env.DB_PASSWORD && process.env.DB_NAME,
);

export const pool = databaseConfigured
  ? new Pool({
      host: process.env.DB_HOST,
      port: Number.parseInt(process.env.DB_PORT ?? '5432', 10),
      user: process.env.DB_USER,
      password: process.env.DB_PASSWORD,
      database: process.env.DB_NAME,
      ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : false,
      max: 8,
      idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 5_000,
    })
  : null;

pool?.on('error', () => {
  console.error('[database] An idle PostgreSQL connection failed.');
});

export async function databaseHealth() {
  if (!pool) return { configured: false, connected: false };
  try {
    const result = await pool.query('SELECT current_database() AS database, NOW() AS checked_at');
    return {
      configured: true,
      connected: true,
      database: result.rows[0].database,
      checkedAt: result.rows[0].checked_at,
    };
  } catch {
    return { configured: true, connected: false };
  }
}

export async function ensureOidcUser({ subject, installationId, displayName, deviceModel, appVersion }) {
  requireDatabase();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock(hashtext($1))', [`ielts-oidc:${subject}`]);
    let userResult = await client.query(
      `SELECT id, installation_id, display_name, created_at
       FROM app_user WHERE oidc_subject = $1 FOR UPDATE`,
      [subject],
    );
    if (userResult.rowCount === 0) {
      const anonymous = await client.query(
        `SELECT id FROM app_user
         WHERE installation_id = $1 AND oidc_subject IS NULL FOR UPDATE`,
        [installationId],
      );
      if (anonymous.rowCount > 0) {
        userResult = await client.query(
          `UPDATE app_user
           SET oidc_subject = $2,
               display_name = COALESCE($3, display_name),
               last_seen_at = NOW()
           WHERE id = $1
           RETURNING id, installation_id, display_name, created_at`,
          [anonymous.rows[0].id, subject, displayName || null],
        );
      } else {
        const occupiedInstallation = await client.query(
          'SELECT 1 FROM app_user WHERE installation_id = $1',
          [installationId],
        );
        userResult = await client.query(
          `INSERT INTO app_user (id, installation_id, display_name, oidc_subject)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT (oidc_subject) WHERE oidc_subject IS NOT NULL DO UPDATE
           SET display_name = COALESCE(EXCLUDED.display_name, app_user.display_name),
               last_seen_at = NOW()
           RETURNING id, installation_id, display_name, created_at`,
          [randomUUID(), occupiedInstallation.rowCount === 0 ? installationId : null, displayName || null, subject],
        );
      }
    } else {
      await client.query(
        'UPDATE app_user SET last_seen_at = NOW(), display_name = COALESCE($2, display_name) WHERE id = $1',
        [userResult.rows[0].id, displayName || null],
      );
    }
    const user = userResult.rows[0];
    await client.query(
      'INSERT INTO user_setting (user_id) VALUES ($1) ON CONFLICT (user_id) DO NOTHING',
      [user.id],
    );
    const sessionId = randomUUID();
    await client.query(
      `INSERT INTO app_session (id, user_id, device_model, app_version)
       VALUES ($1, $2, $3, $4)`,
      [sessionId, user.id, deviceModel || null, appVersion || null],
    );
    await client.query('COMMIT');
    return { user, sessionId };
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

export async function findUserIdByOidcSubject(subject) {
  requireDatabase();
  const result = await pool.query('SELECT id FROM app_user WHERE oidc_subject = $1', [subject]);
  return result.rows[0]?.id ?? null;
}

export async function insertPracticeAttempt(input) {
  requireDatabase();
  if (input.sessionId) {
    await requireOwnedRecord(
      'SELECT 1 FROM app_session WHERE id = $1 AND user_id = $2',
      [input.sessionId, input.userId],
      'Session does not belong to user.',
    );
  }
  const id = randomUUID();
  const result = await pool.query(
    `INSERT INTO practice_attempt (
       id, user_id, session_id, accent, topic, level, reference_text,
       transcript_text, focus_text, overall_score, accuracy_score,
       completeness_score, fluency_score, next_requirements, created_at
     ) VALUES (
       $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14::jsonb, $15
     ) RETURNING id, created_at`,
    [
      id,
      input.userId,
      input.sessionId || null,
      input.accent,
      input.topic,
      input.level,
      input.reference,
      input.transcript,
      input.focus,
      input.overall,
      input.accuracy,
      input.completeness,
      input.fluency,
      JSON.stringify(input.requirements ?? []),
      input.createdAt ?? new Date(),
    ],
  );
  if (input.sessionId) {
    await pool.query('UPDATE app_session SET last_active_at = NOW() WHERE id = $1', [
      input.sessionId,
    ]);
  }
  return result.rows[0];
}

export async function listPracticeAttempts(userId, { page, pageSize }, executor = pool) {
  if (!executor) requireDatabase();
  const countResult = await executor.query(
    'SELECT COUNT(*)::int AS total FROM practice_attempt WHERE user_id = $1',
    [userId],
  );
  const metadata = pageMetadata(Number(countResult.rows[0]?.total ?? 0), { page, pageSize });
  const result = await executor.query(
    `SELECT id, accent, topic, level, reference_text, transcript_text,
            focus_text, overall_score, accuracy_score, completeness_score,
            fluency_score, next_requirements, created_at
     FROM practice_attempt
     WHERE user_id = $1
     ORDER BY created_at DESC, id DESC
     LIMIT $2 OFFSET $3`,
    [userId, pageSize, (metadata.page - 1) * pageSize],
  );
  return { rows: result.rows, ...metadata };
}

export async function saveConversationExchange({
  userId,
  sessionId,
  conversationId,
  practiceAttemptId,
  userContent,
  assistantContent,
}) {
  requireDatabase();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    if (sessionId) {
      await requireOwnedRecord(
        'SELECT 1 FROM app_session WHERE id = $1 AND user_id = $2',
        [sessionId, userId],
        'Session does not belong to user.',
        client,
      );
    }
    if (practiceAttemptId) {
      await requireOwnedRecord(
        'SELECT 1 FROM practice_attempt WHERE id = $1 AND user_id = $2',
        [practiceAttemptId, userId],
        'Practice attempt does not belong to user.',
        client,
      );
    }
    const resolvedConversationId = conversationId || randomUUID();
    if (!conversationId) {
      await client.query(
        `INSERT INTO ai_conversation (id, user_id, session_id)
         VALUES ($1, $2, $3)`,
        [resolvedConversationId, userId, sessionId || null],
      );
    } else {
      const owned = await client.query(
        'SELECT 1 FROM ai_conversation WHERE id = $1 AND user_id = $2',
        [conversationId, userId],
      );
      if (owned.rowCount === 0) throw new Error('Conversation does not belong to user.');
    }
    await client.query(
      `INSERT INTO ai_message (id, conversation_id, practice_attempt_id, role, content)
       VALUES ($1, $2, $3, 'user', $4), ($5, $2, $3, 'assistant', $6)`,
      [
        randomUUID(),
        resolvedConversationId,
        practiceAttemptId || null,
        userContent,
        randomUUID(),
        assistantContent,
      ],
    );
    await client.query('UPDATE ai_conversation SET updated_at = NOW() WHERE id = $1', [
      resolvedConversationId,
    ]);
    await client.query('COMMIT');
    return resolvedConversationId;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

function requireDatabase() {
  if (!pool) throw new Error('Database is not configured.');
}

async function requireOwnedRecord(query, values, message, client = pool) {
  const result = await client.query(query, values);
  if (result.rowCount === 0) {
    const error = new Error(message);
    error.code = 'APP_OWNERSHIP';
    throw error;
  }
}
