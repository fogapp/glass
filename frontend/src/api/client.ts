const TOKEN_KEY = "glass_api_token";

export class ApiError extends Error {
  status: number;
  errors: string[];

  constructor(status: number, errors: string[]) {
    super(errors[0] ?? `HTTP ${status}`);
    this.name = "ApiError";
    this.status = status;
    this.errors = errors;
  }
}

/**
 * Storage can be missing or throw on access: a private window, blocked site
 * data, or a test runtime whose global `localStorage` is a stub. A token that
 * can't be read is simply absent — the request goes out unauthenticated and
 * the server answers 401, which the console already knows how to handle.
 */
function storage(): Storage | null {
  try {
    return typeof localStorage === "undefined" || localStorage === null ? null : localStorage;
  } catch {
    return null;
  }
}

export const tokenStore = {
  get: (): string | null => {
    try {
      return storage()?.getItem(TOKEN_KEY) ?? null;
    } catch {
      return null;
    }
  },
  set: (token: string) => {
    try {
      storage()?.setItem(TOKEN_KEY, token);
    } catch {
      // Nowhere to keep it; this session stays signed in until reload.
    }
  },
  clear: () => {
    try {
      storage()?.removeItem(TOKEN_KEY);
    } catch {
      // Nothing stored means nothing to clear.
    }
  },
};

/**
 * How long to wait before deciding the server is never going to answer.
 * Generous — resolving a source or testing an integration makes the request
 * wait on somebody else's server — but finite, because a fetch with no timeout
 * has no failure state at all: the query stays pending forever, ErrorState
 * never renders, and the console just sits there looking like it's thinking.
 */
const TIMEOUT_MS = 45_000;

/**
 * What the server said about a failed request, for showing beside the form
 * that sent it — or `fallback` when the failure wasn't the server's answer.
 */
export function apiErrorMessage(error: unknown, fallback: string): string {
  return error instanceof ApiError ? error.errors.join(", ") : fallback;
}

/**
 * A request that never produced a readable response, in the console's words.
 * 0 rather than a real status, because there wasn't one: nothing came back.
 * A timeout is told apart from a network failure so the console can say
 * which it was — "still working on it" and "can't reach it" call for
 * different things from the person reading.
 */
function translateFetchError(error: unknown): never {
  if (error instanceof DOMException && error.name === "TimeoutError") {
    throw new ApiError(0, ["The server didn't answer in time"]);
  }
  // A cancellation is TanStack's own doing — rethrow untranslated so it is
  // recognized as one, never surfaced as a network failure.
  if (error instanceof DOMException && error.name === "AbortError") throw error;
  throw new ApiError(0, ["Couldn't reach the server"]);
}

/**
 * `api.get<T>` trusts T — there is no runtime validation by design, so
 * src/types must move in lockstep with the serializers.
 */
type RequestOptions = { signal?: AbortSignal };

async function request<T>(
  method: string,
  path: string,
  body?: unknown,
  options?: RequestOptions,
): Promise<T> {
  return (await send<T>(method, path, body, options)).payload;
}

/** One page of a server-paged list: the rows, and how many there are in all. */
export interface Page<T> {
  rows: T[];
  total: number;
  /** The server stops counting at a ceiling; true when `total` is that ceiling. */
  capped: boolean;
}

async function send<T>(
  method: string,
  path: string,
  body: unknown,
  options: RequestOptions | undefined,
): Promise<{ payload: T; headers: Headers }> {
  const token = tokenStore.get();
  const headers: Record<string, string> = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  // FormData sets its own multipart boundary — a manual Content-Type here
  // would break the upload.
  const isForm = body instanceof FormData;
  if (body !== undefined && !isForm) headers["Content-Type"] = "application/json";

  // The caller's signal (TanStack passes one per query) composed with the
  // timeout: a superseded request — a slider dragged past its debounce rest
  // point firing another full server-side ranking pass — should be aborted,
  // not left running to completion while holding a connection slot.
  const timeout = AbortSignal.timeout(TIMEOUT_MS);
  const signal = options?.signal ? anySignal([options.signal, timeout]) : timeout;

  let response: Response;
  try {
    response = await fetch(`/api/v1${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : isForm ? body : JSON.stringify(body),
      signal,
    });
  } catch (error) {
    translateFetchError(error);
  }

  if (response.status === 204) return { payload: undefined as T, headers: response.headers };

  // The body read sits under the same signal as the headers: a server that
  // answers and then stalls streaming raises the same TimeoutError here, and
  // it must get the same translation — otherwise the raw DOMException walks
  // past every `instanceof ApiError` check and the UI shows the generic
  // fallback instead of the message written for this case.
  let text: string;
  try {
    text = await response.text();
  } catch (error) {
    translateFetchError(error);
  }
  // A gateway that gave up on the app answers with its own HTML page, not
  // our JSON envelope — that must surface as the status it is, not as a
  // parse exception before the status is ever looked at.
  let payload: unknown;
  try {
    payload = text ? JSON.parse(text) : undefined;
  } catch {
    throw new ApiError(response.status, [
      response.ok ? "The server returned something that wasn't JSON" : `HTTP ${response.status}`,
    ]);
  }

  if (!response.ok) {
    throw new ApiError(response.status, extractErrors(payload, response.status));
  }
  return { payload: payload as T, headers: response.headers };
}

/**
 * AbortSignal.any, with a fallback for browsers that predate it (Chrome
 * before 116, Safari before 17.4): a console that silently never loads a
 * chart on an older browser is a bug nobody can diagnose from a chart.
 */
function anySignal(signals: AbortSignal[]): AbortSignal {
  if (typeof AbortSignal.any === "function") return AbortSignal.any(signals);
  const controller = new AbortController();
  for (const signal of signals) {
    if (signal.aborted) {
      controller.abort(signal.reason);
      break;
    }
    signal.addEventListener("abort", () => controller.abort(signal.reason), { once: true });
  }
  return controller.signal;
}

function extractErrors(payload: unknown, status: number): string[] {
  if (payload && typeof payload === "object" && "errors" in payload) {
    const errors = (payload as { errors: unknown }).errors;
    if (Array.isArray(errors)) return errors.map(String);
  }
  return [`HTTP ${status}`];
}

/**
 * A paged list endpoint (the backend's `paginate`): the body stays a bare
 * array and the total rides in `X-Total-Count`. A response without the header
 * is a server that didn't page, so the rows it sent are all there is.
 */
async function getPage<T>(path: string, options?: RequestOptions): Promise<Page<T>> {
  const { payload, headers } = await send<T[]>("GET", path, undefined, options);
  const rows = payload ?? [];
  const header = Number.parseInt(headers.get("X-Total-Count") ?? "", 10);
  return {
    rows,
    total: Number.isFinite(header) ? header : rows.length,
    capped: headers.get("X-Total-Count-Capped") === "true",
  };
}

export const api = {
  get: <T>(path: string, options?: RequestOptions) => request<T>("GET", path, undefined, options),
  getPage,
  post: <T>(path: string, body?: unknown, options?: RequestOptions) =>
    request<T>("POST", path, body ?? {}, options),
  /** Multipart upload (backup artifacts) — body is FormData, not JSON. */
  postForm: <T>(path: string, form: FormData, options?: RequestOptions) =>
    request<T>("POST", path, form, options),
  put: <T>(path: string, body?: unknown, options?: RequestOptions) =>
    request<T>("PUT", path, body ?? {}, options),
  patch: <T>(path: string, body?: unknown, options?: RequestOptions) =>
    request<T>("PATCH", path, body ?? {}, options),
  delete: <T>(path: string, options?: RequestOptions) =>
    request<T>("DELETE", path, undefined, options),
};
