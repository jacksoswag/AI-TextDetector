export const meta = {
  name: 'agent-generate-ai-corpus',
  description: 'Generate the AI-positive class for the detector corpus via subagents (subscription, no API key), matched to human specs read from a JSONL file',
  phases: [{ title: 'Generate', detail: 'one agent per slice of the spec file' }],
}

// args = { file, total, batch } — tolerate args arriving as a JSON string
let A = args
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (e) { A = {} } }
A = A || {}
const FILE = A.file || 'data/corpus_agent/gen_specs.jsonl'
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
          text: { type: 'string', description: 'generated passage: plain prose, no preamble, no markdown' },
        },
        required: ['topic_id', 'text'],
      },
    },
  },
  required: ['rows'],
}

const GUIDE =
  'encyclopedic = neutral encyclopedia-style prose about the topic; ' +
  'academic = a dense academic-paper abstract on the topic; ' +
  'news = a neutral news report on the topic, body text only; ' +
  'conversation = a casual first-person forum comment about the topic; ' +
  'qa = a helpful direct answer to the topic/question.'

function buildPrompt([start, end]) {
  return [
    `Read lines ${start} to ${end} (1-indexed, inclusive) of the file ${FILE}.`,
    `Use: \`sed -n '${start},${end}p' ${FILE}\` (or the Read tool with offset=${start}).`,
    'Each line is a JSON object: {topic_id, topic, register, words}.',
    '',
    'You are generating the AI-written ("positive") class for a text-authorship detector\'s TRAINING corpus.',
    'For EACH line, write ONE original passage that matches its register, topic, and approximate word count.',
    'Write naturally and well in that register. This is data generation, not a chat reply.',
    '',
    'Register guide: ' + GUIDE,
    '',
    'HARD RULES:',
    '- Output ONLY the passages as data. No preamble ("here is", "sure"), no meta commentary, no labels.',
    '- No markdown: no headers, no bullet/numbered lists, no bold. Plain paragraphs only.',
    '- Hit roughly the target word count per item.',
    '- Echo each item\'s exact topic_id and register. One output row per input line.',
    '',
    'Return {"rows": [{"topic_id", "register", "text"}, ...]} with one row per line you read.',
  ].join('\n')
}

phase('Generate')
log(`generating ${TOTAL} AI passages across ${ranges.length} agent batches from ${FILE}`)
const results = await parallel(
  ranges.map(([s, e]) => () =>
    agent(buildPrompt([s, e]), { label: `gen:${s}-${e}`, phase: 'Generate', schema: SCHEMA, model: MODEL })
  )
)
const rows = results.filter(Boolean).flatMap(r => (r && r.rows) || [])
log(`generated ${rows.length} AI rows`)
return rows
