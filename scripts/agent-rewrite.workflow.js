export const meta = {
  name: 'agent-rewrite-ai-corpus',
  description: 'Content-matched AI generation via subagents (subscription, no API rate limits): rewrite each human passage preserving every figure/entity, so density is shared and only authorship differs',
  phases: [{ title: 'Rewrite', detail: 'one agent per slice of the human-passage file' }],
}

// args = { file, total, batch } — file is JSONL of {topic_id, register, text} human rows
let A = args
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (e) { A = {} } }
A = A || {}
const FILE = A.file || 'data/corpus_reg/register_full.jsonl'
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
          text: { type: 'string', description: 'the rewrite: same facts/figures, reworded, plain prose' },
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
    'Each line is a JSON object {topic_id, register, text}. The text is HUMAN-written.',
    '',
    'You are generating the AI-written ("positive") class for a text-authorship detector by',
    'REWRITING each human passage. This is content-matched data generation, not a chat reply.',
    '',
    'For EACH line, rewrite the text in your own words and a different sentence structure, but:',
    '- Preserve EVERY number, dollar amount, percentage, date, and proper noun EXACTLY as written.',
    '- Add no new figures or facts. Round nothing. Drop nothing factual.',
    '- Keep the same register and approximately the same length.',
    '- Genuinely reword and restructure (do not echo the original sentence-by-sentence).',
    '',
    'HARD RULES: output ONLY the rewrites as data. No preamble ("here is", "sure"), no meta,',
    'no markdown, no bullet lists. Plain paragraphs. Echo each item\'s exact topic_id and register.',
    'One output row per input line.',
    '',
    'Return {"rows": [{"topic_id", "register", "text"}, ...]} with one row per line you read.',
  ].join('\n')
}

phase('Rewrite')
log(`content-matched rewrite of ${TOTAL} human passages across ${ranges.length} agent batches`)
const results = await parallel(
  ranges.map(([s, e]) => () =>
    agent(buildPrompt([s, e]), { label: `rewrite:${s}-${e}`, phase: 'Rewrite', schema: SCHEMA, model: MODEL })
  )
)
const rows = results.filter(Boolean).flatMap(r => (r && r.rows) || [])
log(`produced ${rows.length} content-matched AI rows`)
return rows
