export const meta = {
  name: 'agent-disguise-ai-corpus',
  description: 'Humanize/disguise a slice of clean AI passages via subagents — minted hard positives (label stays AI) the detector is currently blind to',
  phases: [{ title: 'Disguise', detail: 'one agent per slice of the clean-AI file' }],
}

// args = { file, total, batch } — file is a JSONL of clean AI rows {topic_id, register, text}
let A = args
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (e) { A = {} } }
A = A || {}
const FILE = A.file || 'data/corpus_big/ai_clean_sample.jsonl'
const TOTAL = Number(A.total) || 0
const BATCH = Number(A.batch) || 16
const MODEL = A.model || 'haiku'   // explicit worker tier — never inherit Opus

const ranges = []
for (let s = 1; s <= TOTAL; s += BATCH) ranges.push([s, Math.min(TOTAL, s + BATCH - 1)])

const SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    rows: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          topic_id: { type: 'string' },
          register: { type: 'string' },
          text: { type: 'string', description: 'the humanized rewrite, plain prose' },
        },
        required: ['topic_id', 'text'],
      },
    },
  },
  required: ['rows'],
}

function buildPrompt([start, end]) {
  return [
    `Read lines ${start} to ${end} (1-indexed, inclusive) of the file ${FILE}.`,
    `Use: \`sed -n '${start},${end}p' ${FILE}\` (or the Read tool with offset=${start}).`,
    'Each line is a JSON object: {topic_id, register, text}. The text is AI-written.',
    '',
    'For EACH item, rewrite the text so it reads like a real person wrote it:',
    '- vary sentence length and rhythm (mix short and long), avoid uniform structure',
    '- use plainer, more concrete wording; drop hedging filler and over-balanced phrasing',
    '- allow one small natural imperfection (a slightly loose transition, an aside)',
    '- preserve the original meaning, register, and approximate length',
    '',
    'These rewrites are still machine-origin (they stay labeled AI). The point is to mint',
    'HUMANIZED / disguised positives that defeat stylometry. Do not add facts.',
    '',
    'HARD RULES: output ONLY the rewrites as data. No preamble, no meta, no markdown.',
    'Echo each item\'s exact topic_id and register. One output row per input line.',
    '',
    'Return {"rows": [{"topic_id", "register", "text"}, ...]} with one row per line you read.',
  ].join('\n')
}

phase('Disguise')
log(`humanizing ${TOTAL} AI passages across ${ranges.length} agent batches from ${FILE}`)
const results = await parallel(
  ranges.map(([s, e]) => () =>
    agent(buildPrompt([s, e]), { label: `disguise:${s}-${e}`, phase: 'Disguise', schema: SCHEMA, model: MODEL })
  )
)
const rows = results.filter(Boolean).flatMap(r => (r && r.rows) || [])
log(`humanized ${rows.length} AI rows`)
return rows
