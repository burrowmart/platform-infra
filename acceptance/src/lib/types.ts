export interface CheckResult {
  id: string;
  title: string;
  criterion: string;
  pass: boolean;
  startedAt: string;
  finishedAt: string;
  durationMs: number;
  /** Markdown-safe evidence blocks (log excerpts, grep output, query results). */
  evidence: EvidenceBlock[];
  /** One-line human summary of what happened. */
  summary: string;
  /** Set when the check couldn't complete (vs. completing and failing an assertion). */
  error?: string;
}

export interface EvidenceBlock {
  label: string;
  /** Rendered as a fenced code block. */
  content: string;
  lang?: string;
}

export function evidence(label: string, content: string, lang = 'text'): EvidenceBlock {
  // Cap each block so one runaway log dump can't blow up the report.
  const MAX = 8000;
  const trimmed = content.length > MAX ? content.slice(0, MAX) + `\n... [truncated ${content.length - MAX} chars]` : content;
  return { label, content: trimmed, lang };
}
