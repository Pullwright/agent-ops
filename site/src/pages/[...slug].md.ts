// A raw-Markdown twin of every documentation page, at the same path with a
// `.md` suffix — e.g. /guides/operating/watch/ also serves as
// /guides/operating/watch.md. Agents following issue #2100's acceptance
// criteria read this instead of parsing rendered HTML.
import type { APIRoute } from 'astro';
import { getCollection, type CollectionEntry } from 'astro:content';

export async function getStaticPaths() {
  const entries = await getCollection('docs');
  return entries.map((entry: CollectionEntry<'docs'>) => ({
    params: { slug: entry.id },
    props: { entry },
  }));
}

export const GET: APIRoute = ({ props }) => {
  const entry = (props as { entry: CollectionEntry<'docs'> }).entry;
  return new Response(entry.body ?? '', {
    status: 200,
    headers: { 'content-type': 'text/markdown; charset=utf-8' },
  });
};
