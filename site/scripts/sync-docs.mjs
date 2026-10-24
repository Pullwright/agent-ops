#!/usr/bin/env node
// site/scripts/sync-docs.mjs — build docs/ (plus a handful of root files) into
// this site's Starlight content collection.
//
// The repository's own Markdown stays the single source of truth: nothing
// here is committed, every page under site/src/content/docs/ is regenerated
// by this script on every `npm run build`/`npm run dev`, from the real files
// under docs/, tech-debt/ and the repository root. That is what lets the same
// Markdown render correctly on GitHub (no frontmatter this script adds is
// read by GitHub, and nothing it strips is required there) and serve as a
// Starlight page (which needs a `title` key, a git-derived `lastUpdated`, and
// internal links rewritten from "relative to the source file" to "relative to
// the site").
//
// docs/reviews/project-review-*/ and tech-debt/ are copied in, not left out
// entirely (requirement: "reachable only from the records index") — they are
// just marked hidden from the sidebar and excluded from Pagefind.

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SITE_ROOT = path.resolve(__dirname, '..');
const REPO_ROOT = path.resolve(SITE_ROOT, '..');
const CONTENT_ROOT = path.join(SITE_ROOT, 'src', 'content', 'docs');

const REPO_SLUG = 'Pullwright/agent-ops';
// Must match astro.config.mjs's `base` — hardcoded links in Markdown content
// are not rewritten by Astro the way its own generated navigation is.
const SITE_BASE = '/agent-ops';
const GITHUB_BLOB = (p) => `https://github.com/${REPO_SLUG}/blob/main/${p}`;
const GITHUB_EDIT = (p) => `https://github.com/${REPO_SLUG}/edit/main/${p}`;

function walk(dir, out = []) {
  for (const name of readdirSync(dir).sort()) {
    const full = path.join(dir, name);
    const st = statSync(full);
    if (st.isDirectory()) walk(full, out);
    else if (name.endsWith('.md')) out.push(full);
  }
  return out;
}

function toRepoRel(absPath) {
  return path.relative(REPO_ROOT, absPath).split(path.sep).join('/');
}

// --- last-updated dates, read once from git history for every path at once ---

// A shallow clone is refused rather than worked around. Its one commit has no
// parent, so `git log --name-only` diffs it against the empty tree and names
// every file in the repository at that single timestamp — every page would
// then carry the build's own date as its "last updated", a wrong answer shaped
// exactly like a right one (the build stays green and warns about nothing).
// CI asks for the whole history (`fetch-depth: 0`, .github/workflows/docs-site.yml);
// a local shallow checkout wants `git fetch --unshallow`.
function assertFullHistory() {
  let shallow;
  try {
    shallow = execFileSync('git', ['rev-parse', '--is-shallow-repository'], {
      cwd: REPO_ROOT,
    })
      .toString('utf8')
      .trim();
  } catch {
    return; // no git at all — buildLastUpdatedMap's own fallback covers it
  }
  if (shallow === 'true') {
    throw new Error(
      'sync-docs: this is a shallow clone, so per-page last-updated dates ' +
        'cannot be read from git history. Run `git fetch --unshallow` (CI ' +
        'uses actions/checkout with fetch-depth: 0).'
    );
  }
}

function buildLastUpdatedMap() {
  const map = new Map();
  let log;
  try {
    log = execFileSync(
      'git',
      ['log', '--name-only', '--no-renames', '--format=COMMIT\t%cI'],
      { cwd: REPO_ROOT, maxBuffer: 1024 * 1024 * 256 }
    ).toString('utf8');
  } catch {
    return map;
  }
  let currentDate = null;
  for (const line of log.split('\n')) {
    if (line.startsWith('COMMIT\t')) {
      currentDate = line.slice('COMMIT\t'.length).trim();
      continue;
    }
    const file = line.trim();
    if (!file || currentDate === null) continue;
    // git log prints newest commits first, so the first date seen for a path
    // is its most recent change.
    if (!map.has(file)) map.set(file, currentDate);
  }
  return map;
}

// --- a minimal flat-key frontmatter reader/writer (none of this repo's
// frontmatter blocks nest or use lists, so a line-based reader is enough) ---

function splitFrontmatter(raw) {
  if (!raw.startsWith('---\n') && !raw.startsWith('---\r\n')) {
    return { fm: {}, body: raw };
  }
  const end = raw.indexOf('\n---', 3);
  if (end === -1) return { fm: {}, body: raw };
  const fmBlock = raw.slice(raw.indexOf('\n') + 1, end);
  let rest = raw.slice(end + 4);
  if (rest.startsWith('\r\n')) rest = rest.slice(2);
  else if (rest.startsWith('\n')) rest = rest.slice(1);
  const fm = {};
  for (const line of fmBlock.split(/\r?\n/)) {
    const m = /^([A-Za-z0-9_-]+):\s*(.*)$/.exec(line);
    if (!m) continue;
    let value = m[2].trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    fm[m[1]] = value;
  }
  return { fm, body: rest };
}

function yamlString(value) {
  const s = String(value);
  if (/^[\w./:#\- ]*$/.test(s) && !s.startsWith(' ') && !s.endsWith(' ')) {
    // Still quote if it could be misread as a YAML special (true/false/null,
    // a number, or something starting with a character that opens a scalar).
    if (!/^(true|false|null|~)$/i.test(s) && !/^[\d-]/.test(s)) return s;
  }
  return JSON.stringify(s);
}

function stripLeadingH1(body) {
  const lines = body.split('\n');
  let i = 0;
  while (i < lines.length && lines[i].trim() === '') i++;
  if (i < lines.length && /^#\s+\S/.test(lines[i])) {
    let j = i + 1;
    while (j < lines.length && lines[j].trim() === '') j++;
    return lines.slice(j).join('\n');
  }
  return body;
}

// --- the manifest: every source file this site publishes, and where it lands ---

const manifest = []; // { repoRel, destSlug (posix, no leading/trailing slash, '' = site root), hidden }
const bySlugKey = new Map(); // lowercase repoRel -> entry, for link resolution

function addEntry(repoRel, destSlug, hidden = false) {
  const entry = { repoRel, destSlug, hidden };
  manifest.push(entry);
  bySlugKey.set(repoRel.toLowerCase(), entry);
}

const PROJECT_REVIEW_RE = /^docs\/reviews\/project-review-[^/]+\//;

for (const abs of walk(path.join(REPO_ROOT, 'docs'))) {
  const repoRel = toRepoRel(abs); // e.g. docs/guides/operating/watch.md
  const underDocs = repoRel.slice('docs/'.length); // guides/operating/watch.md

  if (repoRel === 'docs/README.md') {
    addEntry(repoRel, 'map');
    continue;
  }

  if (PROJECT_REVIEW_RE.test(repoRel)) {
    const rest = repoRel.replace(/^docs\/reviews\//, ''); // project-review-2026-.../NN-x.md
    const destDir = 'records/reviews/' + path.dirname(rest).toLowerCase();
    const base = path.basename(rest, '.md').toLowerCase();
    const destSlug = base === 'readme' ? destDir : destDir + '/' + base;
    addEntry(repoRel, destSlug, true);
    continue;
  }

  const dir = path.dirname(underDocs); // '.' for top-level docs/*.md
  const base = path.basename(underDocs, '.md');
  let destSlug;
  if (base.toLowerCase() === 'readme') {
    destSlug = dir === '.' ? '' : dir.toLowerCase();
    destSlug = destSlug === '' ? 'index' : destSlug + '/index';
  } else {
    destSlug = (dir === '.' ? base : dir + '/' + base).toLowerCase();
  }
  addEntry(repoRel, destSlug);
}

for (const abs of walk(path.join(REPO_ROOT, 'tech-debt'))) {
  const repoRel = toRepoRel(abs);
  const base = path.basename(repoRel, '.md').toLowerCase();
  addEntry(repoRel, 'records/tech-debt/' + base, true);
}

const ROOT_FILES = {
  'README.md': 'index',
  'AGENTS.md': 'project/agents',
  'CONTRIBUTING.md': 'project/contributing',
  'SECURITY.md': 'project/security',
  'TECH-DEBT.md': 'project/tech-debt-policy',
  'CHANGELOG.md': 'project/changelog',
  'CLAUDE.md': 'project/claude',
};
for (const [file, destSlug] of Object.entries(ROOT_FILES)) {
  if (existsSync(path.join(REPO_ROOT, file))) addEntry(file, destSlug);
}

// --- link rewriting ---

function resolveLinkTarget(srcRepoRel, target) {
  if (
    /^(https?:)?\/\//.test(target) ||
    target.startsWith('mailto:') ||
    target.startsWith('#')
  ) {
    return null; // left untouched by the caller
  }
  const hashIdx = target.indexOf('#');
  const pathPart = hashIdx === -1 ? target : target.slice(0, hashIdx);
  const hashPart = hashIdx === -1 ? '' : target.slice(hashIdx);
  if (pathPart === '') return null;

  const base = pathPart.startsWith('/')
    ? pathPart.slice(1)
    : path.posix.join(path.posix.dirname(srcRepoRel), pathPart);
  const normalized = path.posix.normalize(base);

  const entry = bySlugKey.get(normalized.toLowerCase());
  if (entry) {
    // A directory's own `README.md` lands at e.g. `guides/operating/index.md`
    // so Astro emits a clean `/guides/operating/` route — the file needs the
    // literal `index` segment, the href must not repeat it.
    const routeSlug = entry.destSlug.replace(/(^|\/)index$/, '');
    const href = routeSlug === '' ? '/' : '/' + routeSlug + '/';
    return SITE_BASE + href + hashPart;
  }
  // Not one of ours (an image, LICENCE, a path outside the synced set) — link
  // to the real file on GitHub instead of a 404.
  return GITHUB_BLOB(normalized) + hashPart;
}

function rewriteLinks(srcRepoRel, body) {
  return body.replace(/\]\(([^)\s]+)\)/g, (full, target) => {
    const resolved = resolveLinkTarget(srcRepoRel, target);
    if (resolved === null) return full;
    return '](' + resolved + ')';
  });
}

// --- per-file transform ---

assertFullHistory();
const lastUpdated = buildLastUpdatedMap();
const RECOGNIZED_FRONTMATTER = new Set(['title', 'description']);

function buildPage(entry) {
  const abs = path.join(REPO_ROOT, entry.repoRel);
  const raw = readFileSync(abs, 'utf8');
  const { fm, body: rawBody } = splitFrontmatter(raw);

  let title = fm.title;
  if (!title) {
    const firstLine = rawBody.split(/\r?\n/).find((l) => l.trim() !== '');
    const h1 = firstLine && /^#\s+(.+)$/.exec(firstLine);
    title = h1 ? h1[1].trim() : entry.repoRel;
  }
  let body = stripLeadingH1(rawBody);
  body = rewriteLinks(entry.repoRel, body);

  const usedAsDescription = fm.description ? 'description' : fm.summary ? 'summary' : null;
  const extras = Object.keys(fm).filter(
    (k) => !RECOGNIZED_FRONTMATTER.has(k) && k !== 'title' && k !== usedAsDescription
  );
  if (extras.length > 0) {
    const line =
      '*' + extras.map((k) => `${cap(k)}: ${fm[k]}`).join(' · ') + '*\n\n';
    body = line + body;
  }

  const fmOut = {
    title,
    editUrl: GITHUB_EDIT(entry.repoRel),
  };
  if (fm.description) fmOut.description = fm.description;
  else if (fm.summary) fmOut.description = fm.summary;

  let fmLines = Object.entries(fmOut).map(([k, v]) => `${k}: ${yamlString(v)}`);
  const lu = lastUpdated.get(entry.repoRel);
  if (lu) fmLines.push(`lastUpdated: ${lu}`); // unquoted so YAML parses it as a date, not a string
  if (entry.hidden) {
    fmLines.push('sidebar:');
    fmLines.push('  hidden: true');
    fmLines.push('pagefind: false');
  }

  return '---\n' + fmLines.join('\n') + '\n---\n\n' + body;
}

function cap(k) {
  return k.charAt(0).toUpperCase() + k.slice(1);
}

// --- the landing page is a transform of the root README, not a plain copy ---

function buildLanding() {
  const abs = path.join(REPO_ROOT, 'README.md');
  const raw = readFileSync(abs, 'utf8');
  const { body: rawBody } = splitFrontmatter(raw);
  const body = rewriteLinks('README.md', stripLeadingH1(rawBody));
  const lu = lastUpdated.get('README.md');

  const fmLines = [
    'title: Pullwright',
    'description: ' +
      yamlString(
        'A self-hosted, unattended pipeline that selects, implements, and reviews pending work in a GitHub repository.'
      ),
    'editUrl: ' + GITHUB_EDIT('README.md'),
    'template: splash',
    'hero:',
    '  tagline: ' +
      yamlString(
        'Routine engineering work — tech debt, triaged issues, review feedback, security findings — picked up and carried to a pull request without a human having to start each one by hand.'
      ),
    '  actions:',
    "    - text: 'Start here'",
    `      link: '${SITE_BASE}/project/contributing/'`,
    "      icon: right-arrow",
    "    - text: 'Documentation map'",
    `      link: '${SITE_BASE}/map/'`,
    '      variant: minimal',
  ];
  if (lu) fmLines.push(`lastUpdated: ${lu}`);

  return '---\n' + fmLines.join('\n') + '\n---\n\n' + body;
}

// --- the records index: the one navigable, searchable page that links into
// the hidden project-review and tech-debt archives ---

function buildRecordsIndex() {
  const reviews = manifest
    .filter((e) => e.destSlug.startsWith('records/reviews/') && e.destSlug.split('/').length === 3)
    .sort((a, b) => a.destSlug.localeCompare(b.destSlug));
  const debt = manifest
    .filter((e) => e.destSlug.startsWith('records/tech-debt/'))
    .sort((a, b) => a.destSlug.localeCompare(b.destSlug));

  let body = `This page is the one entry point to two archives that are kept out of the
sidebar and out of search, so routine browsing and searching stay focused on
current, as-built documentation:

- **Dated project reviews** (\`docs/reviews/project-review-*/\`) — point-in-time
  generated reports.
- **The tech-debt archive** (\`tech-debt/\`) — the frozen, pre-issue-tracker
  register described in [the tech-debt policy](${SITE_BASE}/project/tech-debt-policy/).

## Project reviews

`;
  for (const r of reviews) {
    const label = r.destSlug.replace('records/reviews/', '');
    body += `- [${label}](${SITE_BASE}/${r.destSlug}/)\n`;
  }
  body += '\n## Tech-debt archive\n\n';
  for (const d of debt) {
    const label = d.destSlug.replace('records/tech-debt/', '');
    body += `- [${label}](${SITE_BASE}/${d.destSlug}/)\n`;
  }

  const fmLines = ['title: Records', 'description: ' + yamlString('Project reviews and the frozen tech-debt archive.')];
  return '---\n' + fmLines.join('\n') + '\n---\n\n' + body;
}

// --- write everything out ---

function writeFile(destSlug, content) {
  const relPath = destSlug === '' ? 'index.md' : destSlug + '.md';
  const full = path.join(CONTENT_ROOT, relPath);
  mkdirSync(path.dirname(full), { recursive: true });
  writeFileSync(full, content, 'utf8');
}

rmSync(CONTENT_ROOT, { recursive: true, force: true });
mkdirSync(CONTENT_ROOT, { recursive: true });

for (const entry of manifest) {
  if (entry.destSlug === 'index') continue; // never produced (README.md maps to 'index' only at docs root, which does not occur)
  writeFile(entry.destSlug, buildPage(entry));
}
writeFile('', buildLanding());
writeFile('records/index', buildRecordsIndex());

console.log(`sync-docs: wrote ${manifest.length + 2} pages to ${path.relative(REPO_ROOT, CONTENT_ROOT)}`);
