const DEFAULT_PAGE_SIZE = 20;
const MAX_PAGE_SIZE = 100;

function positiveInteger(value, fallback) {
  const raw = String(value ?? '');
  if (!/^\d+$/.test(raw)) return fallback;
  const parsed = Number(raw);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

export function parsePageParams(query = {}) {
  const pageSize = Math.min(positiveInteger(query.pageSize, DEFAULT_PAGE_SIZE), MAX_PAGE_SIZE);
  const page = Math.min(
    positiveInteger(query.page, 1),
    Math.floor(Number.MAX_SAFE_INTEGER / pageSize),
  );
  return { page, pageSize, offset: (page - 1) * pageSize };
}

export function pageMetadata(total, { page, pageSize }) {
  const safeTotal = Math.max(0, Number(total) || 0);
  const totalPages = Math.max(1, Math.ceil(safeTotal / pageSize));
  return {
    total: safeTotal,
    page: Math.min(page, totalPages),
    pageSize,
    totalPages,
  };
}
