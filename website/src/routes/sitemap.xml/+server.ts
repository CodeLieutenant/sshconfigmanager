import { locales, baseLocale, localizeHref } from '$lib/paraglide/runtime';
import { PUBLIC_ROUTES } from '$lib/routes';
import { absoluteUrl } from '$lib/seo';

export const prerender = true;

function withTrailingSlash(href: string): string {
  return href.endsWith('/') ? href : `${href}/`;
}

function urlEntry(path: string): string {
  const alternates = locales
    .map(
      (locale) =>
        `    <xhtml:link rel="alternate" hreflang="${locale}" href="${absoluteUrl(withTrailingSlash(localizeHref(path, { locale })))}"/>`
    )
    .join('\n');
  return `  <url>\n    <loc>${absoluteUrl(withTrailingSlash(localizeHref(path, { locale: baseLocale })))}</loc>\n${alternates}\n  </url>`;
}

export function GET() {
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
${PUBLIC_ROUTES.map(urlEntry).join('\n')}
</urlset>
`;
  return new Response(body, { headers: { 'content-type': 'application/xml' } });
}
