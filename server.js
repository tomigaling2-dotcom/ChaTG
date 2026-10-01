const http = require('http');
const { GoogleGenAI } = require('@google/genai');
require('dotenv').config({ path: require('path').join(__dirname, '.env') });

const PORT = Number(
  process.env.PORT || 3000,
);

const HOST =
  process.env.HOST || '0.0.0.0';

const MAX_BODY_BYTES = Number(
  process.env.MAX_BODY_BYTES ||
    25 * 1024 * 1024,
);

const GEMINI_MODEL =
  process.env.GEMINI_MODEL ||
  'gemini-3.8-flash';

const GEMINI_FALLBACKS = [
  process.env.GEMINI_FALLBACK_MODEL,
  'gemini-3.7-flash',
  'gemini-3.6-flash',
  'gemini-3.5-flash-lite',
  'gemini-2.5-flash-lite',
  'gemini-3.8-flash',
].filter(Boolean);

const GEMINI_SEARCH_MODEL =
  process.env.GEMINI_SEARCH_MODEL ||
  'gemini-2.5-flash-lite';

const GEMINI_SEARCH_FALLBACKS = [
  'gemini-3.8-flash',
];

const DEEPSEEK_MODEL =
  process.env.DEEPSEEK_MODEL ||
  'deepseek-chat';

const OPENROUTER_MODEL =
  process.env.OPENROUTER_MODEL ||
  'openrouter/free';

const OPENROUTER_IMAGE_MODEL = process.env.OPENROUTER_IMAGE_MODEL ?? 'bytedance-seed/seedream-4.5';

const HF_IMAGE_MODEL =
  process.env.HF_IMAGE_MODEL ||
  'stabilityai/stable-diffusion-3-medium-diffusers';

const HF_IMAGE_PROVIDER =
  process.env.HF_IMAGE_PROVIDER ||
  'hf-inference';

const HF_EDIT_MODEL =
  process.env.HF_EDIT_MODEL ||
  'Qwen/Qwen-Image-Edit';

const HF_EDIT_PROVIDER =
  process.env.HF_EDIT_PROVIDER ||
  'fal-ai';

const ai = process.env.GEMINI_API_KEY
  ? new GoogleGenAI({
      apiKey: process.env.GEMINI_API_KEY,
    })
  : null;

let hfPromise = null;

const memory = [];

function json(
  res,
  status,
  payload,
) {
  res.writeHead(status, {
    'Content-Type':
        'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers':
        'Content-Type',
    'Access-Control-Allow-Methods':
        'GET,POST,DELETE,OPTIONS',
  });

  res.end(
    JSON.stringify(payload),
  );
}

function errorMessage(error) {
  return error instanceof Error
      ? error.message
      : String(
          error ||
              'Unknown server error.',
        );
}

function requireKey(
  value,
  name,
) {
  if (!value) {
    throw new Error(
      `${name} is not configured on the backend.`,
    );
  }
}

const FREE_DAILY_IMAGE_LIMIT = Number(process.env.FREE_DAILY_IMAGE_LIMIT || 10);
const imageQuota = new Map();

function getImageQuota(userId) {
  const id = String(userId || '').trim();
  if (!id) throw new Error('userId is required for image quota.');
  const day = new Date().toISOString().slice(0, 10);
  const key = id + ':' + day;
  const used = imageQuota.get(key) || 0;
  return {
    key,
    used,
    remaining: Math.max(
      0,
      FREE_DAILY_IMAGE_LIMIT - used,
    ),
  };
}

function consumeImageQuota(userId) {
  const quota = getImageQuota(userId);

  if (quota.remaining <= 0) {
    throw new Error(
      'Daily free image limit reached (' +
        FREE_DAILY_IMAGE_LIMIT +
        ').',
    );
  }

  const used = quota.used + 1;
  imageQuota.set(quota.key, used);

  return {
    used,
    remaining: Math.max(
      0,
      FREE_DAILY_IMAGE_LIMIT - used,
    ),
  };
}
function unique(values) {
  return [
    ...new Set(
      values.filter(Boolean),
    ),
  ];
}

const AUTO_SEARCH_PATTERNS = [
  /\b(latest|today|tonight|tomorrow|yesterday|current|currently|now)\b/i,
  /\b(news|weather|price|prices|stock|score|scores|result|results)\b/i,
  /\b(recent|recently|this week|this month|this year)\b/i,
  /\b(who is|what happened|when is|where is)\b/i,
  /\b(search|look up|find online|on the internet|on web|website|official site)\b/i,
];

function shouldUseWebSearch(message) {
  const text = String(message || '').trim();

  if (!text) return false;

  // Explicit search intent in common Latin-script wording.
  if (AUTO_SEARCH_PATTERNS.some((pattern) => pattern.test(text))) {
    return true;
  }

  // Automatic current-information detection for non-Latin languages.
  // The script check is language-independent; the intent check uses
  // Unicode character patterns instead of embedding native-language text.
  const hasNonLatinScript =
    /[^\u0000-\u007F]/u.test(text);

  const hasCurrentSignal =
    /\b(today|now|latest|current|recent|news|weather|price|prices|score|scores|result|results|search|online|internet|official)\b/i.test(text) ||
    /\b20[2-9][0-9]\b/.test(text) ||
    /[\u0900-\u097F\u0980-\u09FF\u0A00-\u0A7F\u0A80-\u0AFF\u0B00-\u0B7F\u0B80-\u0BFF\u0C00-\u0C7F\u0C80-\u0CFF\u0D00-\u0D7F\u0D80-\u0DFF\u0600-\u06FF\u4E00-\u9FFF\u3040-\u30FF\uAC00-\uD7AF]/u.test(text);

  return hasNonLatinScript && hasCurrentSignal;
}
function lower(error) {
  return errorMessage(
    error,
  ).toLowerCase();
}

function retryable(error) {
  const t = lower(error);

  return [
    'resource_exhausted',
    'quota exceeded',
    'rate limit',
    '429',
    '402',
    'insufficient credits',
    '503',
    '504',
    'unavailable',
    'temporarily',
    'timeout',
    'timed out',
    'fetch failed',
    'network',
  ].some(
    (x) => t.includes(x),
  );
}

function parseBase64(value) {
  if (!value) return null;

  const s = String(value);
  const comma = s.indexOf(',');

  return comma >= 0
      ? s.slice(comma + 1)
      : s;
}

function safeHistory(history) {
  if (!Array.isArray(history)) {
    return [];
  }

  return history
      .slice(-50)
      .map((m) => ({
        role:
            m?.role ===
                'assistant' ||
            m?.role === 'system'
          ? m.role
          : 'user',
        content:
            String(
              m?.content || '',
            ),
      }))
      .filter(
        (m) =>
            m.content.trim(),
      );
}

function memoryText() {
  return memory
      .slice(-20)
      .map((m) => m.text)
      .filter(Boolean)
      .join('\n');
}

function historyText(history) {
  return safeHistory(history)
      .map(
        (m) =>
            `${m.role}: ${m.content}`,
      )
      .join('\n');
}

function buildPrompt(
  message,
  history,
  web,
) {
  return [
    'You are ChaTG, a helpful AI assistant.',
    'Answer clearly, naturally, and accurately.',
    memoryText()
        ? `Saved memory:\n${memoryText()}`
        : '',
    historyText(history)
        ? `Conversation:\n${historyText(history)}`
        : '',
    web
        ? 'Use Google Search for current or changing information when needed.'
        : 'Do not browse unless necessary.',
    `User: ${String(message || '').trim()}`,
  ]
      .filter(Boolean)
      .join('\n\n');
}
const SEARXNG_INSTANCE =
  process.env.SEARXNG_INSTANCE ||
  'https://search.lumy.live';

async function searxngWebSearch(
  query,
) {
  const text =
    String(query || '').trim();

  if (!text) {
    throw new Error(
      'Search query is empty.',
    );
  }

  // Local search normalization: do not consume Gemini quota.
  const stopWords = new Set([
    'a','an','the','is','are','am','was','were','what','why','how','where','when','site','par','ki','ka','ke','kya','hai','hain','kaise','kab','kahaan','mein','me','se','ko','ke','aur','ye','yah','yeh','mujhe','batao','bata','today','abhi','ab','please'
  ]);
  const localQuery = text
    .replace(/[?!.!,;:]+/g, ' ')
    .split(/\s+/)
    .filter((word) => word && !stopWords.has(word.toLowerCase()))
    .join(' ')
    .trim();


  const controller =
    new AbortController();

  const timeout =
    setTimeout(
      () => controller.abort(),
      30000,
    );

  try {
    const url =
      SEARXNG_INSTANCE +
      '/search?q=' +
      encodeURIComponent(text) +
      '&format=json';

    const response =
      await fetch(
        url,
        {
          method: 'GET',
          headers: {
            Accept:
              'application/json',
            'User-Agent':
              'ChaTG/1.0',
          },
          signal:
            controller.signal,
        },
      );

    if (!response.ok) {
      throw new Error(
        `SearXNG request failed (${response.status}).`,
      );
    }

    const data =
      await response.json();

    const results =
      Array.isArray(
        data?.results,
      )
        ? data.results
            .filter(
              (item) =>
                item?.url &&
                item?.title,
            )
            .slice(0, 8)
            .map(
              (item) => ({
                title:
                  String(
                    item.title,
                  ),
                url:
                  String(
                    item.url,
                  ),
                snippet:
                  String(
                    item.content ||
                      '',
                  ),
              }),
            )
        : [];

    if (!results.length) {
      throw new Error(
        'SearXNG returned no usable results.',
      );
    }

    return results;
  } finally {
    clearTimeout(timeout);
  }
}

async function geminiSearchSynthesis(
  message,
  history,
  sources,
) {
  const enrichedSources =
    await Promise.all(
      sources.map(
        async (source) => {
          const pageContent =
            await fetchWebPageContent(
              source.url,
            );

          return {
            ...source,
            pageContent,
          };
        },
      ),
    );

  const sourceText =
    enrichedSources
      .map(
        (source, index) =>
          `[${index + 1}] ${source.title}\n` +
          `${source.url}\n` +
          `Search snippet: ${source.snippet}\n` +
          `Webpage content: ${source.pageContent || 'Page content could not be fetched.'}`,
      )
      .join('\n\n');

  const prompt = [
    'Answer the user using the supplied web search results and fetched webpage content.',
    'When webpage content is available, use it as the primary evidence for website-specific information.',
    'Use search snippets only as supporting evidence.',
    'Do not invent facts, URLs, or webpage content.',
    'If a webpage could not be fetched, clearly avoid claiming that you read its full page.',
    'For current information, rely only on the supplied search results and fetched webpage content.',
    'Answer in the SAME LANGUAGE and SAME WRITING SYSTEM as the user.',
    'Do not unnecessarily switch to English.',
    '',
    'WEB SOURCES:',
    sourceText,
    '',
    'USER QUESTION:',
    String(message || ''),
  ].join('\n');

  const result =
    await geminiText(
      prompt,
      history,
      false,
    );

  return {
    ...result,
    sources:
      enrichedSources,
  };
}
async function normalizeSearchQuery(
  message,
  history,
) {
  const text =
    String(
      message || '',
    ).trim();

  if (!text) {
    throw new Error(
      'Search query is empty.',
    );
  }

  // Local search normalization: do not consume Gemini quota.
  const stopWords = new Set([
    'a','an','the','is','are','am','was','were','what','why','how','where','when','site','par','ki','ka','ke','kya','hai','hain','kaise','kab','kahaan','mein','me','se','ko','ke','aur','ye','yah','yeh','mujhe','batao','bata','today','abhi','ab','please'
  ]);
  const localQuery = text
    .replace(/[?!.!,;:]+/g, ' ')
    .split(/\s+/)
    .filter((word) => word && !stopWords.has(word.toLowerCase()))
    .join(' ')
    .trim();


  // Latin/English/Roman-script queries
  // can be searched directly.
  if (
    /^[\x00-\x7F]*$/u.test(text)
  ) {
    return localQuery || text;
  }

  try {
    const result =
      await geminiText(
        [
          'Convert the user question into one concise English web-search query.',
          'Return ONLY the search query.',
          'Do not answer the question.',
          'Preserve names, places, organizations, products, dates and numbers.',
          'The original question may use any language or script.',
          `User question: ${text}`,
        ].join('\n'),
        history,
        false,
      );

    const query =
      String(
        result?.text || '',
      )
        .replace(
          /^```[\s\S]*?\n|\n```$/g,
          '',
        )
        .trim();

    return query || text;
  } catch (error) {
    console.warn(
      'Search query normalization failed; using original query.',
      errorMessage(error),
    );

    return localQuery || text;
  }
}
async function readJson(req) {
  return new Promise(
    (resolve, reject) => {
      let total = 0;
      const chunks = [];
      let rejected = false;

      req.on(
        'data',
        (chunk) => {
          if (rejected) return;

          total += chunk.length;

          if (
            total >
            MAX_BODY_BYTES
          ) {
            rejected = true;

            reject(
              new Error(
                'Request body is too large.',
              ),
            );

            req.destroy();
            return;
          }

          chunks.push(chunk);
        },
      );

      req.on(
        'end',
        () => {
          if (rejected) return;

          try {
            const raw =
                Buffer.concat(
                  chunks,
                ).toString('utf8');

            resolve(
              raw
                  ? JSON.parse(raw)
                  : {},
            );
          } catch (_) {
            reject(
              new Error(
                'Invalid JSON body.',
              ),
            );
          }
        },
      );

      req.on(
        'error',
        reject,
      );
    },
  );
}

async function geminiGenerate(
  model,
  contents,
  useWebSearch = false,
) {
  requireKey(
    process.env.GEMINI_API_KEY,
    'GEMINI_API_KEY',
  );

  const config =
      useWebSearch
        ? {
            tools: [
              {
                googleSearch: {},
              },
            ],
          }
        : undefined;

  return ai.models.generateContent({
    model,
    contents,
    ...(config
        ? { config }
        : {}),
  });
}

async function geminiText(
  message,
  history,
  useWebSearch,
) {
  const models =
      useWebSearch
        ? unique([
            GEMINI_SEARCH_MODEL,
            ...GEMINI_SEARCH_FALLBACKS,
          ])
        : unique([
            GEMINI_MODEL,
            ...GEMINI_FALLBACKS,
          ]);

  let lastError;

  for (const model of models) {
    try {
      const response =
          await geminiGenerate(
            model,
            buildPrompt(
              message,
              history,
              useWebSearch,
            ),
            useWebSearch,
          );

      return {
        text:
            response.text ||
            'The model returned no text.',
        model,
      };
    } catch (error) {
      lastError = error;

      if (!retryable(error)) {
        throw error;
      }

      console.warn(
        `Gemini model ${model} failed; trying fallback.`,
        errorMessage(error),
        error,
      );
    }
  }

  throw (
    lastError ||
    new Error(
      'All configured Gemini models failed.',
    )
  );
}

async function geminiPdf({
  message,
  history,
  useWebSearch,
  fileBase64,
  fileMimeType,
}) {
  requireKey(
    process.env.GEMINI_API_KEY,
    'GEMINI_API_KEY',
  );

  const data =
      parseBase64(fileBase64);

  if (!data) {
    throw new Error(
      'The PDF is empty or invalid.',
    );
  }

  const prompt = [
    buildPrompt(
      message,
      history,
      useWebSearch,
    ),
    'Read the attached PDF as the primary source.',
    'Answer from the PDF contents. Use its text, tables, charts, diagrams, and page context when relevant.',
  ].join('\n\n');

  const models =
      useWebSearch
        ? unique([
            GEMINI_SEARCH_MODEL,
            ...GEMINI_SEARCH_FALLBACKS,
          ])
        : unique([
            GEMINI_MODEL,
            ...GEMINI_FALLBACKS,
          ]);

  let lastError;

  for (const model of models) {
    try {
      const response =
          await geminiGenerate(
            model,
            [
              {
                role: 'user',
                parts: [
                  {
                    text: prompt,
                  },
                  {
                    inlineData: {
                      mimeType:
                          fileMimeType ||
                          'application/pdf',
                      data,
                    },
                  },
                ],
              },
            ],
            useWebSearch,
          );

      return {
        text:
            response.text ||
            'The PDF was received, but no answer was returned.',
        model,
      };
    } catch (error) {
      lastError = error;

      if (!retryable(error)) {
        throw error;
      }

      console.warn(
        `Gemini PDF model ${model} failed; trying fallback.`,
        errorMessage(error),
        error,
      );
    }
  }

  throw (
    lastError ||
    new Error(
      'All configured Gemini PDF models failed.',
    )
  );
}

async function deepseekChat(
  message,
  history,
) {
  requireKey(
    process.env.DEEPSEEK_API_KEY,
    'DEEPSEEK_API_KEY',
  );

  const response =
      await fetch(
        'https://api.deepseek.com/chat/completions',
        {
          method: 'POST',
          headers: {
            'Content-Type':
                'application/json',
            Authorization:
                `Bearer ${process.env.DEEPSEEK_API_KEY}`,
          },
          body: JSON.stringify({
            model:
                DEEPSEEK_MODEL,
            messages: [
              {
                role: 'system',
                content:
                    'You are ChaTG, a helpful AI assistant.',
              },
              ...safeHistory(
                history,
              ),
              {
                role: 'user',
                content: message,
              },
            ],
          }),
        },
      );

  const data =
      await response
          .json()
          .catch(() => ({}));

  if (!response.ok) {
    throw new Error(
      data?.error?.message ||
          `DeepSeek request failed (${response.status}).`,
    );
  }

  return (
    data?.choices?.[0]
        ?.message?.content ||
    'DeepSeek returned no text.'
  );
}

function openRouterKeys() {
  return unique([
    process.env.OPENROUTER_API_KEY,
    process.env.OPENROUTER_API_KEY_1,
    process.env.OPENROUTER_API_KEY_2,
  ]);
}

async function openRouterChat(
  message,
  history,
) {
  const keys =
      openRouterKeys();

  if (!keys.length) {
    throw new Error(
      'No OpenRouter API key is configured on the backend.',
    );
  }

  const systemContent = [
    'You are ChaTG, a helpful AI assistant.',
    'Answer clearly, naturally, accurately, and helpfully.',
    memoryText()
        ? `Saved memory:\n${memoryText()}`
        : '',
  ]
      .filter(Boolean)
      .join('\n\n');

  let lastError;

  for (const key of keys) {
    try {
      const response =
          await fetch(
            'https://openrouter.ai/api/v1/chat/completions',
            {
              method: 'POST',
              headers: {
                'Content-Type':
                    'application/json',
                Authorization:
                    `Bearer ${key}`,
                'X-Title':
                    'ChaTG',
              },
              body: JSON.stringify({
                model:
                    OPENROUTER_MODEL,
                messages: [
                  {
                    role: 'system',
                    content:
                        systemContent,
                  },
                  ...safeHistory(
                    history,
                  ),
                  {
                    role: 'user',
                    content: message,
                  },
                ],
              }),
            },
          );

      const data =
          await response
              .json()
              .catch(() => ({}));

      if (!response.ok) {
        throw new Error(
          data?.error
              ?.message ||
              `OpenRouter request failed (${response.status}).`,
        );
      }

      return {
        text:
            data?.choices?.[0]
                ?.message?.content ||
            'OpenRouter returned no text.',
        model:
            data?.model ||
            OPENROUTER_MODEL,
      };
    } catch (error) {
      lastError = error;

      console.warn(
        'OpenRouter key failed; trying next key.',
        errorMessage(error),
        error,
      );
    }
  }

  throw (
    lastError ||
    new Error(
      'All configured OpenRouter keys failed.',
    )
  );
}

/*
 * Extract structured Web Search citations from
 * OpenRouter's assistant message.
 *
 * OpenRouter may expose citations through
 * message.annotations / url_citation.
 *
 * Different models/providers can return slightly
 * different shapes, so this helper intentionally
 * accepts several safe variants.
 */
function extractOpenRouterSources(message) {
  const sources = [];
  const seen = new Set();

  function addSource(value) {
    if (!value) return;

    const url =
        typeof value === 'string'
          ? value
          : value?.url ||
            value?.uri ||
            value?.link;

    if (
      typeof url !== 'string' ||
      !/^https?:\/\//i.test(url)
    ) {
      return;
    }

    const normalizedUrl =
        url.trim();

    if (!normalizedUrl) return;

    const key =
        normalizedUrl.toLowerCase();

    if (seen.has(key)) return;

    seen.add(key);

    const title =
        typeof value === 'object'
          ? value?.title ||
            value?.name ||
            ''
          : '';

    const snippet =
        typeof value === 'object'
          ? value?.content ||
            value?.snippet ||
            value?.text ||
            ''
          : '';

    sources.push({
      title:
          String(title || '').trim(),
      url:
          normalizedUrl,
      ...(snippet
          ? {
              snippet:
                  String(
                    snippet,
                  ).trim(),
            }
          : {}),
    });
  }

  function scan(value) {
    if (!value) return;

    if (Array.isArray(value)) {
      for (const item of value) {
        scan(item);
      }
      return;
    }

    if (
      typeof value !== 'object'
    ) {
      return;
    }

    const type =
        String(
          value.type || '',
        ).toLowerCase();

    if (
      type === 'url_citation' ||
      type === 'url-citation' ||
      type === 'citation'
    ) {
      addSource(value);
    }

    if (
      value.url ||
      value.uri ||
      value.link
    ) {
      addSource(value);
    }

    if (
      value.annotations
    ) {
      scan(value.annotations);
    }

    if (
      value.citations
    ) {
      scan(value.citations);
    }

    if (
      value.sources
    ) {
      scan(value.sources);
    }
  }

  scan(
    message?.annotations,
  );

  scan(
    message?.citations,
  );

  scan(
    message?.sources,
  );

  return sources;
}

async function openRouterWebSearchChat(
  message,
  history,
) {
  const currentDate = new Date().toISOString().slice(0, 10);
  const keys =
      openRouterKeys();

  if (!keys.length) {
    throw new Error(
      'No OpenRouter API key is configured on the backend.',
    );
  }

  let lastError;

  for (const key of keys) {
    try {
      const response =
          await fetch(
            'https://openrouter.ai/api/v1/chat/completions',
            {
              method: 'POST',
              headers: {
                'Content-Type':
                    'application/json',
                Authorization:
                    `Bearer ${key}`,
                'X-Title':
                    'ChaTG',
              },
              body: JSON.stringify({
                model:
                    OPENROUTER_MODEL,

                tools: [
                  {
                    type:
                        'openrouter:web_search',
                  },
                ],

                messages: [
                  {
                    role: 'system',
                    content:
                        'You are ChaTG, a helpful AI assistant. ' +
                        'The current date is ' + currentDate + '. Treat this date as authoritative for today/current/latest requests. ' +
                        'When current or changing information is needed, use the web search tool. ' +
                        'Use the search results to provide accurate, grounded answers and citations when available. ' + 'Always answer in the same language and writing system as the user message unless the user asks for another language. Do not mix unrelated languages in the answer. Keep names, numbers, dates, and source titles accurate.',
                  },
                  ...safeHistory(
                    history,
                  ),
                  {
                    role: 'user',
                    content: message,
                  },
                ],
              }),
            },
          );

      const data =
          await response
              .json()
              .catch(() => ({}));

      if (!response.ok) {
        throw new Error(
          data?.error
              ?.message ||
              `OpenRouter Web Search request failed (${response.status}).`,
        );
      }

      const assistantMessage =
          data?.choices?.[0]
              ?.message;

      const text =
          assistantMessage
              ?.content ||
          'OpenRouter Web Search returned no text.';

      const sources =
          extractOpenRouterSources(
            assistantMessage,
          );

      return {
        text,
        model:
            data?.model ||
            OPENROUTER_MODEL,
        sources,
      };
    } catch (error) {
      lastError = error;

      console.warn(
        'OpenRouter Web Search key failed; trying next key.',
        errorMessage(error),
        error,
      );
    }
  }

  throw (
    lastError ||
    new Error(
      'All configured OpenRouter keys failed for Web Search.',
    )
  );
}

async function autoChat(
  message,
  history,
  useWebSearch,
  attachment,
) {
  /*
   * STEP 10.2:
   *
   * Normal Chat -> OpenRouter primary
   * Web Search  -> OpenRouter Web Search
   * PDF        -> Gemini document path
   *
   * Existing fallback providers are preserved.
   */

  if (
    useWebSearch &&
    !attachment?.base64
  ) {
    try {
      const searchQuery =
        await normalizeSearchQuery(message, history);

      const sources =
        await searxngWebSearch(
          searchQuery,
        );

      const reply =
        sources
          .map(
            (item, index) =>
              `${index + 1}. ${item.title}\n${item.snippet || ''}\n${item.url}`,
          )
          .join('\n\n');

      return {
        text:
          reply ||
          'No web search results found.',
        model:
          'searxng',
        sources,
        provider:
          'searxng',
        webSearch:
          true,
      };
    } catch (searchError) {
      console.warn(
        'SearXNG Web Search unavailable; falling back to normal chat.',
        errorMessage(searchError),
      );
    }
  }
  if (attachment?.base64) {
    if (String(attachment.mimeType || '').startsWith('image/')) {
      const image = await analyzeImage(attachment.base64, attachment.mimeType, message);
      return { ...image, provider: 'gemini' };
    }
    if (String(attachment.mimeType || '').startsWith('image/')) {
      const image = await analyzeImage(attachment.base64, attachment.mimeType, message);
      return { ...image, provider: 'gemini' };
    }
    try {
      const pdf =
          await geminiPdf({
            message,
            history,
            useWebSearch,
            fileBase64:
                attachment.base64,
            fileMimeType:
                attachment.mimeType,
          });

      return {
        ...pdf,
        provider: 'gemini',
      };
    } catch (error) {
      if (!retryable(error)) {
        throw error;
      }

      console.warn(
        'Gemini PDF path failed.',
        errorMessage(error),
        error,
      );

      throw error;
    }
  }

  /*
   * NORMAL CHAT
   * OpenRouter is now the primary gateway.
   */
  try {
    const result =
        await openRouterChat(
          message,
          history,
        );

    return {
      ...result,
      provider:
          'openrouter',
    };
  } catch (error) {
    if (!retryable(error)) {
      throw error;
    }

    console.warn(
      'OpenRouter normal chat failed.',
      errorMessage(error),
    );
  }

  /*
   * EXISTING FALLBACK #1
   */
  if (
    process.env
        .DEEPSEEK_API_KEY
  ) {
    try {
      return {
        text:
            await deepseekChat(
              message,
              history,
            ),
        provider:
            'deepseek',
      };
    } catch (deepseekError) {
      console.warn(
        'DeepSeek fallback failed.',
        errorMessage(
          deepseekError,
        ),
      );
    }
  }

  /*
   * EXISTING FALLBACK #2
   */
  try {
    const result =
        await geminiText(
          message,
          history,
          false,
        );

    return {
      ...result,
      provider: 'gemini',
    };
  } catch (geminiError) {
    console.warn(
      'Gemini fallback failed.',
      errorMessage(
        geminiError,
      ),
    );

    throw geminiError;
  }
}

async function getHf() {
  requireKey(
    process.env.HF_TOKEN,
    'HF_TOKEN',
  );

  if (!hfPromise) {
    hfPromise =
        import(
          '@huggingface/inference'
        ).then(
          ({
            InferenceClient,
          }) =>
            new InferenceClient(
              process.env.HF_TOKEN,
            ),
        );
  }

  return hfPromise;
}

async function blobJson(
  blob,
) {
  const bytes =
      Buffer.from(
        await blob.arrayBuffer(),
      );

  return {
    base64:
        bytes.toString(
          'base64',
        ),
    mimeType:
        blob.type || 'image/png',
  };
}

async function generateImageWithOpenRouter(
  prompt,
) {
  const keys = openRouterKeys();

  if (!keys.length) {
    throw new Error(
      'OpenRouter image generation is not configured.',
    );
  }

  let lastError = null;

  for (const key of keys) {
    try {
      const response = await fetch(
        'https://openrouter.ai/api/v1/images',
        {
          method: 'POST',
          headers: {
            'Content-Type':
                'application/json',
            Authorization:
                `Bearer ${key}`,
            'X-Title':
                'ChaTG',
          },
          body: JSON.stringify({
            model:
                OPENROUTER_IMAGE_MODEL,
            prompt:
                String(
                  prompt ||
                      'A beautiful digital artwork',
                ),
          }),
        },
      );

      const data =
          await response
              .json()
              .catch(() => ({}));

      if (!response.ok) {
        throw new Error(
          data?.error?.message ||
              data?.error ||
              `OpenRouter image error: ${response.status}`,
        );
      }

      const image =
          data?.data?.[0];

      if (!image?.b64_json) {
        throw new Error(
          'OpenRouter returned no image data.',
        );
      }

      return {
        base64: image.b64_json,
        mimeType:
            image.media_type ||
            'image/png',
      };
    } catch (error) {
      lastError = error;
    }
  }

  throw lastError ||
      new Error(
        'OpenRouter image generation failed.',
      );
}
async function generateImage(
  prompt,
) {
  try {
    const hf = await getHf();

    const result =
        await hf.textToImage(
          {
            inputs:
                String(
                  prompt ||
                      'A beautiful digital artwork',
                ),
            model:
                HF_IMAGE_MODEL,
            provider:
                HF_IMAGE_PROVIDER,
          },
          {
            outputType: 'blob',
            retry_on_error: false,
          },
        );

    return blobJson(result);
  } catch (hfError) {
    console.warn(
      'Hugging Face image generation failed; trying OpenRouter.',
      hfError?.message || hfError,
    );

    return generateImageWithOpenRouter(
      prompt,
    );
  }
}
async function editImageWithOpenRouter(
  prompt,
  imageBase64,
) {
  const keys = openRouterKeys();

  if (!keys.length) {
    throw new Error(
      'OpenRouter image editing is not configured.',
    );
  }

  const base64Data =
    parseBase64(imageBase64);

  if (!base64Data) {
    throw new Error(
      'The supplied image is empty or invalid.',
    );
  }

  let lastError = null;

  for (const key of keys) {
    try {
      const response = await fetch(
        'https://openrouter.ai/api/v1/images',
        {
          method: 'POST',
          headers: {
            'Content-Type':
                'application/json',
            Authorization:
                `Bearer ${key}`,
            'X-Title':
                'ChaTG',
          },
          body: JSON.stringify({
            model:
                OPENROUTER_IMAGE_MODEL,
            prompt:
                String(
                  prompt ||
                      'Improve this image naturally while keeping the main subject recognizable.',
                ),
            input_references: [
              {
                type:
                    'image_url',
                image_url: {
                  url:
                    `data:image/jpeg;base64,${base64Data}`,
                },
              },
            ],
          }),
        },
      );

      const data =
          await response
              .json()
              .catch(() => ({}));

      if (!response.ok) {
        throw new Error(
          data?.error?.message ||
              data?.error ||
              `OpenRouter image edit error: ${response.status}`,
        );
      }

      const image =
          data?.data?.[0];

      if (!image?.b64_json) {
        throw new Error(
          'OpenRouter returned no edited image data.',
        );
      }

      return {
        base64:
            image.b64_json,
        mimeType:
            image.media_type ||
            'image/png',
      };
    } catch (error) {
      lastError = error;
    }
  }

  throw lastError ||
      new Error(
        'OpenRouter image editing failed.',
      );
}
async function editImage(
  prompt,
  imageBase64,
) {
  try {
    const hf = await getHf();

    const base64Data =
      parseBase64(imageBase64);

    if (!base64Data) {
      throw new Error(
        'The supplied image is empty or invalid.',
      );
    }

    const imageBuffer =
      Buffer.from(
        base64Data,
        'base64',
      );

    if (!imageBuffer.length) {
      throw new Error(
        'The supplied image is empty or invalid.',
      );
    }

    const imageBlob =
      new Blob([
        imageBuffer,
      ]);

    const result =
      await hf.imageToImage(
        {
          inputs: imageBlob,
          model:
            HF_EDIT_MODEL,
          provider:
            HF_EDIT_PROVIDER,
          parameters: {
            prompt: String(
              prompt ||
                'Improve this image naturally while keeping the main subject recognizable.',
            ),
          },
        },
        {
          outputType: 'blob',
          retry_on_error: false,
        },
      );

    return blobJson(result);
  } catch (hfError) {
    console.warn(
      'Hugging Face image editing failed; trying OpenRouter.',
      hfError?.message || hfError,
    );

    return editImageWithOpenRouter(
      prompt,
      imageBase64,
    );
  }
}
async function analyzeImage(
  imageBase64,
  mimeType,
  prompt,
) {
  requireKey(
    process.env.GEMINI_API_KEY,
    'GEMINI_API_KEY',
  );

  const data =
      parseBase64(
        imageBase64,
      );

  if (!data) {
    throw new Error(
      'The image is empty or invalid.',
    );
  }

  const models =
      unique([
        GEMINI_MODEL,
        ...GEMINI_FALLBACKS,
      ]);

  let lastError;

  for (const model of models) {
    try {
      const response =
          await geminiGenerate(
            model,
            [
              {
                role: 'user',
                parts: [
                  {
                    inlineData: {
                      mimeType:
                          mimeType ||
                          'image/jpeg',
                      data,
                    },
                  },
                  {
                    text: String(
                      prompt ||
                          'Describe this image accurately.',
                    ),
                  },
                ],
              },
            ],
            false,
          );

      return {
        reply:
            response.text ||
            'No image analysis was returned.',
        text:
            response.text ||
            'No image analysis was returned.',
        model,
      };
    } catch (error) {
      lastError = error;

      if (!retryable(error)) {
        throw error;
      }
    }
  }

  throw (
    lastError ||
    new Error(
      'All configured image-analysis models failed.',
    )
  );
}

function tools() {
  return [
    {
      id: 'gemini',
      enabled:
          Boolean(
            process.env
                .GEMINI_API_KEY,
          ),
      type: 'ai',
    },
    {
      id: 'deepseek',
      enabled:
          Boolean(
            process.env
                .DEEPSEEK_API_KEY,
          ),
      type: 'ai',
    },
    {
      id: 'openrouter',
      enabled:
          openRouterKeys()
              .length >
          0,
      type: 'ai',
    },
    {
      id:
          'huggingface_image',
      enabled:
          Boolean(
            process.env.HF_TOKEN,
          ),
      type: 'image',
      model:
          HF_IMAGE_MODEL,
    },
    {
      id:
          'huggingface_image_edit',
      enabled:
          Boolean(
            process.env.HF_TOKEN,
          ),
      type: 'image_edit',
      model:
          HF_EDIT_MODEL,
    },
    {
      id:
          'google_search',
      enabled:
          Boolean(
            process.env
                .GEMINI_API_KEY,
          ),
      type: 'tool',
      model:
          GEMINI_SEARCH_MODEL,
    },
  ];
}

async function handle(
  req,
  res,
) {
  if (
    req.method ===
    'OPTIONS'
  ) {
    return json(
      res,
      204,
      {},
    );
  }

  if (
    req.method === 'GET' &&
    req.url === '/health'
  ) {
    return json(
      res,
      200,
      {
        status: 'ok',
        app: 'ChaTG',
        textModel:
            GEMINI_MODEL,
        searchModel:
            GEMINI_SEARCH_MODEL,
        imageModel:
            HF_IMAGE_MODEL,
        editModel:
            HF_EDIT_MODEL,
      },
    );
  }

  if (
    req.method === 'GET' &&
    req.url === '/tools'
  ) {
    return json(
      res,
      200,
      {
        tools: tools(),
      },
    );
  }

  if (
    req.method === 'GET' &&
    req.url === '/memory'
  ) {
    return json(
      res,
      200,
      {
        memory,
      },
    );
  }

  if (
    req.method ===
        'DELETE' &&
    req.url === '/memory'
  ) {
    memory.splice(
      0,
      memory.length,
    );

    return json(
      res,
      200,
      {
        ok: true,
      },
    );
  }

  if (
    req.method ===
        'DELETE' &&
    req.url ===
        '/memory/delete'
  ) {
    const body =
        await readJson(req);

    const index =
        Number(body.index);

    if (
      !Number.isInteger(
        index,
      ) ||
      index < 0 ||
      index >= memory.length
    ) {
      return json(
        res,
        400,
        {
          error:
              'Invalid memory index.',
        },
      );
    }

    memory.splice(
      index,
      1,
    );

    return json(
      res,
      200,
      {
        ok: true,
      },
    );
  }

  if (
    req.method !== 'POST'
  ) {
    return json(
      res,
      404,
      {
        error:
            'Not found.',
      },
    );
  }

  const body =
      await readJson(req);

  const path =
      req.url || '/';

  if (
    path ===
    '/memory/add'
  ) {
    const text =
        String(
          body.text || '',
        ).trim();

    if (!text) {
      return json(
        res,
        400,
        {
          error:
              'Memory text is empty.',
        },
      );
    }

    memory.push({
      text,
      createdAt:
          new Date()
              .toISOString(),
    });

    return json(
      res,
      200,
      {
        ok: true,
        memory,
      },
    );
  }

  if (
    path === '/chat' ||
    path === '/tool'
  ) {
    const message =
        String(
          body.message || '',
        ).trim();

    const history =
        safeHistory(
          body.history,
        );

    const useWebSearch =
        Boolean(body.useWebSearch) ||
        shouldUseWebSearch(message);

    const provider =
        String(
          body.provider ||
              'auto',
        ).toLowerCase();

    const fileBase64 =
        body.fileBase64
            ? String(
                body.fileBase64,
              )
            : null;

    const fileMimeType =
        String(
          body.fileMimeType ||
              '',
        ).toLowerCase();

    const fileName =
        String(
          body.fileName ||
              'attachment',
        );

    const isPdf =
        Boolean(
          fileBase64 &&
              (
                fileMimeType ===
                    'application/pdf' ||
                fileName
                    .toLowerCase()
                    .endsWith(
                      '.pdf',
                    )
              ),
        );

    if (
      !message &&
      !fileBase64
    ) {
      return json(
        res,
        400,
        {
          error:
              'Message is empty.',
        },
      );
    }

    if (fileBase64 && !isPdf && !fileMimeType.startsWith('image/')) {
      return json(
        res,
        415,
        {
          error:
              'Only PDF file attachments are sent as binary files. Text files are parsed in the app.',
        },
      );
    }

    try {
      if (
        provider === 'auto'
      ) {
        const result =
            await autoChat(
              message ||
                  'Read this PDF and help me.',
              history,
              useWebSearch,
              (isPdf || fileMimeType.startsWith('image/'))
                  ? {
                      base64:
                          fileBase64,
                      mimeType:
                          isPdf ? 'application/pdf' : fileMimeType,
                    }
                  : null,
            );

        return json(
          res,
          200,
          {
            reply:
                result.text,
            provider:
                result.provider,
            ...(result.model
                ? {
                    model:
                        result.model,
                  }
                : {}),
            ...(Array.isArray(
              result.sources,
            ) &&
            result.sources.length
                ? {
                    sources:
                        result.sources,
                  }
                : {}),
            ...(result.searchQuery
                ? {
                    searchQuery:
                        result.searchQuery,
                  }
                : {}),
          },
        );
      }

      if (
        provider === 'gemini'
      ) {
        const result =
            isPdf
                ? await geminiPdf({
                    message:
                        message ||
                        'Read this PDF and help me.',
                    history,
                    useWebSearch,
                    fileBase64,
                    fileMimeType:
                        'application/pdf',
                  })
                : await geminiText(
                    message,
                    history,
                    useWebSearch,
                  );

        return json(
          res,
          200,
          {
            reply:
                result.text,
            provider:
                'gemini',
            model:
                result.model,
          },
        );
      }

      if (
        provider ===
        'deepseek'
      ) {
        if (isPdf) {
          return json(
            res,
            400,
            {
              error:
                  'PDF analysis uses the Gemini document-capable path.',
            },
          );
        }

        return json(
          res,
          200,
          {
            reply:
                await deepseekChat(
                  message,
                  history,
                ),
            provider:
                'deepseek',
          },
        );
      }

      if (
        provider ===
        'openrouter'
      ) {
        if (isPdf) {
          return json(
            res,
            400,
            {
              error:
                  'PDF analysis uses the Gemini document-capable path.',
            },
          );
        }

        if (useWebSearch) {
          const result =
              await openRouterWebSearchChat(
                message,
                history,
              );

          return json(
            res,
            200,
            {
              reply:
                  result.text,
              provider:
                  'openrouter',
              ...(result.model
                  ? {
                      model:
                          result.model,
                    }
                  : {}),
              ...(Array.isArray(
                result.sources,
              ) &&
              result.sources.length
                  ? {
                      sources:
                          result.sources,
                    }
                  : {}),
            },
          );
        }

        const result =
            await openRouterChat(
              message,
              history,
            );

        return json(
          res,
          200,
          {
            reply:
                result.text,
            provider:
                'openrouter',
            ...(result.model
                ? {
                    model:
                        result.model,
                  }
                : {}),
          },
        );
      }

      return json(
        res,
        400,
        {
          error:
              `Unknown provider: ${provider}`,
        },
      );
    } catch (error) {
      console.error(
        'Chat error:',
        error,
      );

      return json(
        res,
        502,
        {
          error:
              errorMessage(error),
          provider,
        },
      );
    }
  }

  if (
    path ===
    '/image/analyze'
  ) {
    try {
      const result =
          await analyzeImage(
            body.imageBase64,
            body.mimeType,
            body.prompt,
          );

      return json(
        res,
        200,
        result,
      );
    } catch (error) {
      console.error(
        'Image analysis error:',
        error,
      );

      return json(
        res,
        502,
        {
          error:
              errorMessage(error),
        },
      );
    }
  }

  if (
    path === '/image/edit'
  ) {
    try {
      if (
        !process.env.HF_TOKEN &&
        openRouterKeys().length === 0
      ) {
        return json(
          res,
          503,
          {
            error:
                'Image editing is not configured. Add HF_TOKEN to backend/.env.',
          },
        );
      }

      if (
        !body.imageBase64
      ) {
        return json(
          res,
          400,
          {
            error:
                'imageBase64 is required.',
          },
        );
      }

      const editQuotaStatus = getImageQuota(body.userId); if (editQuotaStatus.remaining <= 0) { return json(res, 429, { error: 'Daily free image limit reached.', quota: editQuotaStatus }); } return json(
        res,
        200,
        await editImage(
          body.prompt,
          body.imageBase64,
        ),
      );
    } catch (error) {
      console.error(
        'Image editing error:',
        error,
      );

      return json(
        res,
        502,
        {
          error:
              `Image editing failed: ${errorMessage(error)}`,
          provider:
              HF_EDIT_PROVIDER,
          model:
              HF_EDIT_MODEL,
        },
      );
    }
  }

  if (
    path ===
    '/image/generate'
  ) {
    try {
      if (
        !process.env.HF_TOKEN &&
        openRouterKeys().length === 0
      ) {
        return json(
          res,
          503,
          {
            error:
                'Image generation is not configured. Add HF_TOKEN to backend/.env.',
          },
        );
      }

      return json(
        res,
        200,
        await generateImage(
          body.prompt,
        ),
      );
    } catch (error) {
      console.error(
        'Image generation error:',
        error,
      );

      return json(
        res,
        502,
        {
          error:
              `Image generation failed: ${errorMessage(error)}`,
          provider:
              HF_IMAGE_PROVIDER,
          model:
              HF_IMAGE_MODEL,
        },
      );
    }
  }

  return json(
    res,
    404,
    {
      error:
          'Not found.',
    },
  );
}

const server =
    http.createServer(
      (req, res) => {
        handle(req, res)
            .catch((error) => {
              console.error(
                error,
              );

              if (
                !res.headersSent
              ) {
                json(
                  res,
                  500,
                  {
                    error:
                        errorMessage(
                          error,
                        ),
                  },
                );
              }
            });
      },
    );

server.listen(
  PORT,
  HOST,
  () => {
    console.log(
      `ChaTG backend running on ${HOST}:${PORT}`,
    );
    console.log(
      `Gemini text model: ${GEMINI_MODEL}`,
    );
    console.log(
      `Gemini search model: ${GEMINI_SEARCH_MODEL}`,
    );
    console.log(
      `HF image model: ${HF_IMAGE_MODEL}`,
    );
    console.log(
      `HF edit model: ${HF_EDIT_MODEL}`,
    );
  },
);










async function fetchWebPageContent(
  url,
) {
  const target =
    String(url || '').trim();

  if (!target) {
    return '';
  }

  const controller =
    new AbortController();

  const timeout =
    setTimeout(
      () => controller.abort(),
      30000,
    );

  try {
    const response =
      await fetch(
        target,
        {
          method: 'GET',
          headers: {
            Accept:
              'text/html,application/xhtml+xml',
            'User-Agent':
              'Mozilla/5.0 (compatible; ChaTG/1.0; +https://chatgpt.com)',
          },
          redirect: 'follow',
          signal:
            controller.signal,
        },
      );

    if (!response.ok) {
      return '';
    }

    const contentType =
      String(
        response.headers.get(
          'content-type',
        ) || '',
      ).toLowerCase();

    if (
      !contentType.includes(
        'text/html',
      ) &&
      !contentType.includes(
        'application/xhtml+xml',
      )
    ) {
      return '';
    }

    const html =
      await response.text();

    if (!html) {
      return '';
    }

    const cleaned =
      html
        .replace(
          /<script[\s\S]*?<\/script>/gi,
          ' ',
        )
        .replace(
          /<style[\s\S]*?<\/style>/gi,
          ' ',
        )
        .replace(
          /<noscript[\s\S]*?<\/noscript>/gi,
          ' ',
        )
        .replace(
          /<svg[\s\S]*?<\/svg>/gi,
          ' ',
        )
        .replace(
          /<[^>]+>/g,
          ' ',
        )
        .replace(
          /&nbsp;/gi,
          ' ',
        )
        .replace(
          /&amp;/gi,
          '&',
        )
        .replace(
          /&quot;/gi,
          '"',
        )
        .replace(
          /&#39;/gi,
          "'",
        )
        .replace(
          /\s+/g,
          ' ',
        )
        .trim();

    return cleaned.slice(
      0,
      12000,
    );
  } catch (error) {
    console.warn(
      'Webpage fetch failed:',
      target,
      errorMessage(error),
    );

    return '';
  } finally {
    clearTimeout(timeout);
  }
}



















