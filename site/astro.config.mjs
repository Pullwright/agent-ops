// site/astro.config.mjs — builds the public documentation site from this
// repository's own docs/ (see site/scripts/sync-docs.mjs, which runs before
// every build and populates src/content/docs/). Containment: this directory
// is the whole of the toolchain (AGENTS.md "Generated regions" / issue #2100)
// — nothing here is copied into the pipeline's node image (see
// .dockerignore and scripts/is-docs-only.sh).
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightLinksValidator from 'starlight-links-validator';
import starlightLlmsTxt from 'starlight-llms-txt';

const REPO = 'Pullwright/agent-ops';

export default defineConfig({
  site: 'https://pullwright.github.io',
  base: '/agent-ops',
  trailingSlash: 'always',
  integrations: [
    starlight({
      title: 'Pullwright',
      description:
        'A self-hosted, unattended pipeline that selects, implements, and reviews pending work in a GitHub repository.',
      social: [{ icon: 'github', label: 'GitHub', href: `https://github.com/${REPO}` }],
      editLink: { baseUrl: `https://github.com/${REPO}/edit/main/` },
      lastUpdated: true,
      pagination: false,
      plugins: [
        starlightLinksValidator({
          errorOnFallbackPages: false,
          exclude: ({ file, link }) => {
            // A pathologically backtick-dense paragraph (illustrating
            // Markdown code-span-matching rules with nested single/double/
            // quadruple-backtick examples) desyncs micromark's inline code
            // tokenizer, so this one placeholder — meant to render as
            // literal code — reads as a real link instead. GitHub's own
            // renderer, and this repo's own scripts/check-docs.sh, both read
            // the paragraph as prose.
            if (file.endsWith('components-02.md') && link.includes('extended-notes-')) {
              return true;
            }
            // Pre-existing stale citation in docs/reference/configuration.md
            // (the heading it names no longer exists in
            // docs/guides/contributing/README.md) — deferred as tech debt
            // rather than fixed here; see this pull request's `Defers:` line.
            if (
              file.endsWith('reference/configuration.md') &&
              link.includes('making-a-change-when-every-instance-is-a-container')
            ) {
              return true;
            }
            return false;
          },
        }),
        starlightLlmsTxt({ projectName: 'Pullwright agent-ops' }),
      ],
      sidebar: [
        { label: 'Documentation map', link: '/map/' },
        {
          label: 'Guides',
          items: [
            { label: 'Working with Pullwright', link: '/guides/working-with-pullwright/' },
            { label: 'Operating', items: [{ autogenerate: { directory: 'guides/operating' } }] },
            { label: 'Contributing', link: '/guides/contributing/' },
          ],
        },
        { label: 'Reference', items: [{ autogenerate: { directory: 'reference' } }] },
        { label: 'Concepts', items: [{ autogenerate: { directory: 'concepts' } }] },
        {
          label: 'Specifications',
          items: [
            {
              label: 'Implementation pipeline',
              items: [{ autogenerate: { directory: 'spec/implementation' } }],
            },
            {
              label: 'Repository-review pipeline',
              items: [{ autogenerate: { directory: 'spec/review' } }],
            },
            {
              label: 'Monitoring dashboard',
              items: [{ autogenerate: { directory: 'spec/dashboard' } }],
            },
            { label: 'Pipeline Monitor', link: '/spec/monitor/' },
          ],
        },
        { label: 'Data handling', link: '/data-handling/' },
        {
          label: 'Planning and decision logs',
          items: [
            { label: 'Roadmap', link: '/roadmap/' },
            { label: 'Standing decisions', link: '/standing-decisions/' },
          ],
        },
        {
          label: 'Audits and investigations',
          items: [
            // These five live in docs/records/, so sync-docs.mjs lands them
            // under the records/ slug prefix; docs/CONSUMER-EXTRACTION-PLAN.md
            // is still a top-level docs/ file and keeps a top-level slug.
            {
              label: 'Phase 1 Poetic-specifics audit',
              link: '/records/phase-1-poetic-specifics-audit/',
            },
            { label: 'Vocabulary sweep #679 audit', link: '/records/vocabulary-sweep-679-audit/' },
            { label: 'Pullwright day-one autonomy', link: '/records/pullwright-day-one-autonomy/' },
            { label: 'Pullwright rehoming', link: '/records/pullwright-rehoming/' },
            { label: 'Consumer extraction plan', link: '/consumer-extraction-plan/' },
            { label: 'Provider seam audit', link: '/records/provider-seam-audit/' },
          ],
        },
        {
          label: 'Dated reviews',
          items: [{ autogenerate: { directory: 'reviews' } }],
        },
        { label: 'Records (reviews archive, tech-debt archive)', link: '/records/' },
        {
          label: 'Project',
          items: [
            { label: 'AGENTS.md (conventions)', link: '/project/agents/' },
            { label: 'CONTRIBUTING.md', link: '/project/contributing/' },
            { label: 'Security policy', link: '/project/security/' },
            { label: 'Tech-debt policy', link: '/project/tech-debt-policy/' },
            { label: 'Changelog', link: '/project/changelog/' },
            { label: 'CLAUDE.md', link: '/project/claude/' },
          ],
        },
      ],
    }),
  ],
});
