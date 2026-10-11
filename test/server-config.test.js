import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import test from 'node:test';

test('health endpoint reports LAN OpenAI-compatible provider without exposing credentials', async () => {
  const probe = createServer();
  probe.listen(0, '127.0.0.1');
  await once(probe, 'listening');
  const { port } = probe.address();
  await new Promise((resolve) => probe.close(resolve));

  const child = spawn(process.execPath, ['server.js'], {
    cwd: new URL('../server/', import.meta.url),
    env: {
      ...process.env,
      PORT: String(port),
      AI_BASE_URL: 'http://192.168.1.9:11434/v1/chat/completions',
      AI_API_KEY: 'test-only-secret',
      AI_MODEL: 'qwen-test',
      DASHSCOPE_API_KEY: '',
      DB_HOST: '',
      DB_USER: '',
      DB_PASSWORD: '',
      DB_NAME: '',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  child.stdout.setEncoding('utf8').on('data', (chunk) => { output += chunk; });
  child.stderr.setEncoding('utf8').on('data', (chunk) => { output += chunk; });

  try {
    const address = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`server did not start: ${output}`)), 5000);
      const poll = async () => {
        const match = output.match(/listening on http:\/\/127\.0\.0\.1:(\d+)/);
        if (match) {
          clearTimeout(timer);
          resolve(match[1]);
          return;
        }
        if (child.exitCode !== null) {
          clearTimeout(timer);
          reject(new Error(`server exited: ${output}`));
          return;
        }
        setTimeout(poll, 25);
      };
      poll();
    });
    const health = await fetch(`http://127.0.0.1:${address}/api/health`).then((response) => response.json());

    assert.equal(health.provider, 'LAN OpenAI-compatible API');
    assert.equal(health.model, 'qwen-test');
    assert.equal(health.configured, true);
    assert.equal(JSON.stringify(health).includes('test-only-secret'), false);
  } finally {
    child.kill();
    await once(child, 'exit');
  }
});
