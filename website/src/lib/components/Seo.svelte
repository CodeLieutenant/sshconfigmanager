<script lang="ts">
  import { page } from '$app/state';
  import { absoluteUrl, SITE } from '$lib/seo';

  type Props = {
    title: string;
    description?: string;
    canonicalPath?: string;
    keywords?: string[];
    image?: string;
    type?: string;
    jsonLd?: Record<string, unknown> | Record<string, unknown>[];
  };

  let {
    title,
    description = SITE.description,
    canonicalPath,
    keywords = SITE.keywords as unknown as string[],
    image = SITE.ogImage,
    type = 'website',
    jsonLd
  }: Props = $props();

  const ogUrl = $derived(absoluteUrl(canonicalPath ?? page.url.pathname));
  const ogImage = $derived(absoluteUrl(image));
  const blocks = $derived(jsonLd ? (Array.isArray(jsonLd) ? jsonLd : [jsonLd]) : []);

  function ldScript(ld: Record<string, unknown>): string {
    const json = JSON.stringify(ld).replace(/</g, '\\u003c');
    const open = '<' + 'script type="application/ld+json">';
    const close = '<' + '/' + 'script>';
    return open + json + close;
  }
</script>

<svelte:head>
  <title>{title}</title>
  <meta name="description" content={description} />
  {#if keywords?.length}
    <meta name="keywords" content={keywords.join(', ')} />
  {/if}

  <meta property="og:title" content={title} />
  <meta property="og:description" content={description} />
  <meta property="og:url" content={ogUrl} />
  <meta property="og:type" content={type} />
  <meta property="og:image" content={ogImage} />
  <meta name="twitter:title" content={title} />
  <meta name="twitter:description" content={description} />
  <meta name="twitter:image" content={ogImage} />

  {#each blocks as block (block['@id'] ?? block['@type'])}
    <!-- eslint-disable-next-line svelte/no-at-html-tags -->
    {@html ldScript(block)}
  {/each}
</svelte:head>
