import assert from 'node:assert/strict';
import test from 'node:test';
import { pageMetadata, parsePageParams } from '../server/pagination.js';
import { listPracticeAttempts } from '../server/database.js';

test('pagination defaults invalid values and caps page size', () => {
  assert.deepEqual(parsePageParams({}), { page: 1, pageSize: 20, offset: 0 });
  assert.deepEqual(parsePageParams({ page: '-4', pageSize: '1000' }), {
    page: 1, pageSize: 100, offset: 0,
  });
  assert.deepEqual(parsePageParams({ page: '3', pageSize: '10' }), {
    page: 3, pageSize: 10, offset: 20,
  });
  assert.ok(Number.isSafeInteger(parsePageParams({ page: '9007199254740991' }).offset));
});

test('page metadata keeps an empty result on page one', () => {
  assert.deepEqual(pageMetadata(0, { page: 1, pageSize: 20 }), {
    total: 0, page: 1, pageSize: 20, totalPages: 1,
  });
  assert.deepEqual(pageMetadata(41, { page: 2, pageSize: 20 }), {
    total: 41, page: 2, pageSize: 20, totalPages: 3,
  });
  assert.deepEqual(pageMetadata(41, { page: 50, pageSize: 20 }), {
    total: 41, page: 3, pageSize: 20, totalPages: 3,
  });
});

test('practice attempt query scopes by user and applies stable page bounds', async () => {
  const calls = [];
  const executor = {
    async query(sql, values) {
      calls.push({ sql, values });
      return sql.includes('COUNT(*)')
        ? { rows: [{ total: 21 }] }
        : { rows: [{ id: 'attempt-21' }] };
    },
  };
  const result = await listPracticeAttempts(
    'user-1', { page: 2, pageSize: 20 }, executor,
  );

  assert.equal(result.total, 21);
  assert.deepEqual(result.rows, [{ id: 'attempt-21' }]);
  assert.deepEqual(calls[0].values, ['user-1']);
  assert.deepEqual(calls[1].values, ['user-1', 20, 20]);
  assert.match(calls[1].sql, /ORDER BY created_at DESC, id DESC/);
  assert.match(calls[1].sql, /LIMIT \$2 OFFSET \$3/);
});
