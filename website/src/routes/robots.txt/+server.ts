import { absoluteUrl } from '$lib/seo';

export const prerender = true;

export function GET() {
  const body = `User-agent: *
Allow: /

Sitemap: ${absoluteUrl('/sitemap.xml')}
`;
  return new Response(body, { headers: { 'content-type': 'text/plain' } });
}
