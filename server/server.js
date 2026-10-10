import http from 'node:http';
import {
  databaseConfigured,
  databaseHealth,
  ensureUser,
  insertPracticeAttempt,
  listPracticeAttempts,
  saveConversationExchange,
} from './database.js';

const port = Number.parseInt(process.env.PORT ?? '8041', 10);
const apiKey = process.env.DASHSCOPE_API_KEY?.trim();
const apiUrl = process.env.DASHSCOPE_API_URL?.trim()
  ?? 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions';
const model = process.env.DASHSCOPE_MODEL?.trim() ?? 'qwen-plus';
const asrModel = process.env.DASHSCOPE_ASR_MODEL?.trim() ?? 'qwen3-asr-flash';

const systemPrompt = `你是一名严谨、友好的 IELTS Speaking 口语教练。你会收到用户问题和可选的跟读上下文。
请遵循这些规则：
1. 默认用简洁中文解释，发音示例保留英文；
2. 区分英式、美式、澳式口音中的可接受差异，不把某一种口音说成唯一正确；
3. 若只有语音识别文本，不要声称听到了具体音素，只能基于漏词、错词、识别置信度和分数作有限判断；
4. 给出可执行练习，优先提供重音、连读、意群和节奏建议；
5. 单次回答尽量控制在 300 个中文字符以内；
6. 只输出纯文本，不使用 Markdown 加粗标记、标题符号或 emoji。`;

const server = http.createServer(async (request, response) => {
  setCorsHeaders(response);
  if (request.method === 'OPTIONS') {
    response.writeHead(204);
    response.end();
    return;
  }

  const requestUrl = new URL(request.url ?? '/', 'http://127.0.0.1');

  if (request.method === 'GET' && requestUrl.pathname === '/api/health') {
    const database = await databaseHealth();
    sendJson(response, 200, {
      ok: true,
      provider: 'Alibaba Cloud Model Studio',
      model,
      asrModel,
      configured: Boolean(apiKey),
      database,
    });
    return;
  }

  if (request.method === 'POST' && requestUrl.pathname === '/api/users/ensure') {
    if (!databaseConfigured) {
      sendJson(response, 503, { error: '数据库尚未配置。' });
      return;
    }
    try {
      const body = await readJson(request);
      const installationId = requireText(body.installationId, 'installationId', 80);
      const record = await ensureUser({
        installationId,
        displayName: optionalText(body.displayName, 80),
        deviceModel: optionalText(body.deviceModel, 160),
        appVersion: optionalText(body.appVersion, 40),
      });
      sendJson(response, 200, {
        userId: record.user.id,
        sessionId: record.sessionId,
        displayName: record.user.display_name,
        createdAt: record.user.created_at,
      });
    } catch (error) {
      handleDatabaseRequestError(response, error, '建立用户会话失败。');
    }
    return;
  }

  if (request.method === 'GET' && requestUrl.pathname === '/api/practice-attempts') {
    if (!databaseConfigured) {
      sendJson(response, 503, { error: '数据库尚未配置。' });
      return;
    }
    try {
      const userId = requireUuid(requestUrl.searchParams.get('userId'), 'userId');
      const requestedLimit = Number.parseInt(requestUrl.searchParams.get('limit') ?? '50', 10);
      const limit = Number.isFinite(requestedLimit) ? Math.min(Math.max(requestedLimit, 1), 100) : 50;
      const records = await listPracticeAttempts(userId, limit);
      sendJson(response, 200, {
        attempts: records.map((record) => ({
          id: record.id,
          accent: record.accent,
          topic: record.topic,
          level: record.level,
          reference: record.reference_text,
          transcript: record.transcript_text,
          focus: record.focus_text,
          overall: record.overall_score,
          accuracy: record.accuracy_score,
          completeness: record.completeness_score,
          fluency: record.fluency_score,
          requirements: record.next_requirements,
          recordingStorage: 'local_device',
          createdAt: record.created_at,
        })),
      });
    } catch (error) {
      handleDatabaseRequestError(response, error, '读取练习历史失败。');
    }
    return;
  }

  if (request.method === 'POST' && requestUrl.pathname === '/api/practice-attempts') {
    if (!databaseConfigured) {
      sendJson(response, 503, { error: '数据库尚未配置。' });
      return;
    }
    try {
      const body = await readJson(request);
      const accent = requireText(body.accent, 'accent', 20);
      if (!['british', 'american', 'australian'].includes(accent)) {
        throw new RequestError(400, 'accent 参数无效。');
      }
      const requirements = Array.isArray(body.requirements)
        ? body.requirements.slice(0, 6).map((item) => requireText(item, 'requirements', 500))
        : [];
      const record = await insertPracticeAttempt({
        userId: requireUuid(body.userId, 'userId'),
        sessionId: optionalUuid(body.sessionId, 'sessionId'),
        accent,
        topic: requireText(body.topic, 'topic', 120),
        level: requireText(body.level, 'level', 30),
        reference: requireText(body.reference, 'reference', 5_000),
        transcript: requireText(body.transcript, 'transcript', 5_000),
        focus: requireText(body.focus, 'focus', 160),
        overall: requireScore(body.overall, 'overall'),
        accuracy: requireScore(body.accuracy, 'accuracy'),
        completeness: requireScore(body.completeness, 'completeness'),
        fluency: requireScore(body.fluency, 'fluency'),
        requirements,
        createdAt: optionalDate(body.createdAt),
      });
      sendJson(response, 201, { id: record.id, createdAt: record.created_at });
    } catch (error) {
      handleDatabaseRequestError(response, error, '保存练习记录失败。');
    }
    return;
  }

  if (request.method === 'POST' && requestUrl.pathname === '/api/transcribe') {
    if (!apiKey) {
      sendJson(response, 503, { error: '本机服务尚未配置 DASHSCOPE_API_KEY。' });
      return;
    }
    try {
      const body = await readJson(request, 8 * 1024 * 1024);
      const audio = typeof body.audio === 'string' ? body.audio : '';
      if (!audio.startsWith('data:audio/wav;base64,') || audio.length < 1_000) {
        sendJson(response, 400, { error: '请提供有效的 WAV 录音。' });
        return;
      }

      const upstream = await fetch(apiUrl, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model: asrModel,
          messages: [
            {
              role: 'user',
              content: [
                { type: 'input_audio', input_audio: { data: audio } },
              ],
            },
          ],
          stream: false,
          asr_options: { language: 'en', enable_itn: true },
        }),
        signal: AbortSignal.timeout(50_000),
      });
      const payload = await upstream.json().catch(() => ({}));
      if (!upstream.ok) {
        console.error(`[transcribe] Upstream request failed with status ${upstream.status}.`);
        sendJson(response, upstream.status === 401 || upstream.status === 403 ? 502 : upstream.status, {
          error: upstream.status === 401 || upstream.status === 403
            ? '百炼语音识别鉴权失败，请检查 API Key 与服务地域。'
            : '百炼语音识别暂时不可用，请稍后重试。',
        });
        return;
      }
      const transcript = payload?.choices?.[0]?.message?.content;
      if (typeof transcript !== 'string' || !transcript.trim()) {
        sendJson(response, 422, { error: '没有识别到有效英语，请再试一次。' });
        return;
      }
      sendJson(response, 200, { transcript: transcript.trim() });
    } catch (error) {
      if (error instanceof RequestError) {
        sendJson(response, error.statusCode, { error: error.message });
        return;
      }
      const timedOut = error instanceof DOMException && error.name === 'TimeoutError';
      console.error(`[transcribe] ${timedOut ? 'Upstream request timed out.' : 'Unexpected request failure.'}`);
      sendJson(response, timedOut ? 504 : 500, {
        error: timedOut ? '百炼语音识别超时，请稍后重试。' : '本机服务处理录音失败。',
      });
    }
    return;
  }

  if (request.method === 'POST' && requestUrl.pathname === '/api/coach') {
    if (!apiKey) {
      sendJson(response, 503, { error: '本机服务尚未配置 DASHSCOPE_API_KEY。' });
      return;
    }

    try {
      const body = await readJson(request);
      const message = typeof body.message === 'string' ? body.message.trim() : '';
      if (!message) {
        sendJson(response, 400, { error: '消息不能为空。' });
        return;
      }

      const history = sanitizeHistory(body.history);
      const context = sanitizePracticeContext(body.practiceContext);
      const messages = [
        { role: 'system', content: systemPrompt },
        ...history,
        {
          role: 'user',
          content: context
            ? `${message}\n\n最近一次跟读数据：\n${JSON.stringify(context, null, 2)}`
            : message,
        },
      ];

      const upstream = await fetch(apiUrl, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ model, messages, temperature: 0.45 }),
        signal: AbortSignal.timeout(35_000),
      });
      const payload = await upstream.json().catch(() => ({}));
      if (!upstream.ok) {
        const status = upstream.status === 401 || upstream.status === 403 ? 502 : upstream.status;
        console.error(`[coach] Upstream request failed with status ${upstream.status}.`);
        sendJson(response, status, {
          error: upstream.status === 401 || upstream.status === 403
            ? '百炼鉴权失败，请检查 API Key 与服务地域。'
            : '百炼服务暂时不可用，请稍后重试。',
        });
        return;
      }

      const reply = payload?.choices?.[0]?.message?.content;
      if (typeof reply !== 'string' || !reply.trim()) {
        sendJson(response, 502, { error: '百炼返回了无法识别的响应。' });
        return;
      }
      let conversationId = optionalUuid(body.conversationId, 'conversationId');
      let persisted = false;
      const userId = optionalUuid(body.userId, 'userId');
      if (databaseConfigured && userId) {
        try {
          conversationId = await saveConversationExchange({
            userId,
            sessionId: optionalUuid(body.sessionId, 'sessionId'),
            conversationId,
            practiceAttemptId: optionalUuid(body.practiceAttemptId, 'practiceAttemptId'),
            userContent: message,
            assistantContent: reply.trim(),
          });
          persisted = true;
        } catch {
          console.error('[coach] Saving the conversation to PostgreSQL failed.');
        }
      }
      sendJson(response, 200, { reply: reply.trim(), conversationId, persisted });
    } catch (error) {
      if (error instanceof RequestError) {
        sendJson(response, error.statusCode, { error: error.message });
        return;
      }
      const timedOut = error instanceof DOMException && error.name === 'TimeoutError';
      console.error(`[coach] ${timedOut ? 'Upstream request timed out.' : 'Unexpected request failure.'}`);
      sendJson(response, timedOut ? 504 : 500, {
        error: timedOut ? '百炼响应超时，请稍后重试。' : '本机服务处理请求失败。',
      });
    }
    return;
  }

  sendJson(response, 404, { error: '接口不存在。' });
});

server.listen(port, '127.0.0.1', () => {
  console.log(`IELTS Accent Lab server listening on http://127.0.0.1:${port}`);
  console.log(`Model Studio: ${apiKey ? `configured (${model})` : 'not configured'}`);
});

function setCorsHeaders(response) {
  response.setHeader('Access-Control-Allow-Origin', '*');
  response.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  response.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
}

function sendJson(response, statusCode, body) {
  response.writeHead(statusCode, { 'Content-Type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(body));
}

function readJson(request, maximumBytes = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let body = '';
    request.setEncoding('utf8');
    request.on('data', (chunk) => {
      body += chunk;
      if (Buffer.byteLength(body, 'utf8') > maximumBytes) {
        reject(new RequestError(413, '请求内容过大。'));
        request.destroy();
      }
    });
    request.on('end', () => {
      try {
        resolve(JSON.parse(body || '{}'));
      } catch {
        reject(new RequestError(400, '请求必须是合法 JSON。'));
      }
    });
    request.on('error', reject);
  });
}

function sanitizeHistory(value) {
  if (!Array.isArray(value)) return [];
  return value
    .filter((item) => item && ['user', 'assistant'].includes(item.role) && typeof item.content === 'string')
    .slice(-8)
    .map((item) => ({ role: item.role, content: item.content.slice(0, 2_000) }));
}

function sanitizePracticeContext(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const allowedKeys = [
    'accent',
    'reference',
    'transcript',
    'focus',
    'overall',
    'accuracy',
    'completeness',
    'fluency',
  ];
  return Object.fromEntries(
    allowedKeys
      .filter((key) => ['string', 'number'].includes(typeof value[key]))
      .map((key) => [key, value[key]]),
  );
}

class RequestError extends Error {
  constructor(statusCode, message) {
    super(message);
    this.statusCode = statusCode;
  }
}

function requireText(value, field, maximumLength) {
  if (typeof value !== 'string' || !value.trim()) {
    throw new RequestError(400, `${field} 不能为空。`);
  }
  const text = value.trim();
  if (text.length > maximumLength) {
    throw new RequestError(400, `${field} 内容过长。`);
  }
  return text;
}

function optionalText(value, maximumLength) {
  if (value == null || value === '') return null;
  if (typeof value !== 'string' || value.trim().length > maximumLength) {
    throw new RequestError(400, '文本参数无效。');
  }
  return value.trim();
}

function requireUuid(value, field) {
  const uuid = requireText(value, field, 36);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(uuid)) {
    throw new RequestError(400, `${field} 格式无效。`);
  }
  return uuid;
}

function optionalUuid(value, field) {
  return value == null || value === '' ? null : requireUuid(value, field);
}

function requireScore(value, field) {
  if (!Number.isInteger(value) || value < 0 || value > 100) {
    throw new RequestError(400, `${field} 必须是 0 到 100 的整数。`);
  }
  return value;
}

function optionalDate(value) {
  if (value == null || value === '') return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) throw new RequestError(400, 'createdAt 格式无效。');
  return date;
}

function handleDatabaseRequestError(response, error, fallbackMessage) {
  if (error instanceof RequestError) {
    sendJson(response, error.statusCode, { error: error.message });
    return;
  }
  if (error?.code === '23503') {
    sendJson(response, 409, { error: '用户或会话不存在，请重新打开应用。' });
    return;
  }
  if (error?.code === 'APP_OWNERSHIP') {
    sendJson(response, 403, { error: '用户、会话或练习记录不匹配。' });
    return;
  }
  console.error(`[database] ${fallbackMessage}`);
  sendJson(response, 500, { error: fallbackMessage });
}
