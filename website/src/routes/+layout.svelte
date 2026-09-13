<script lang="ts">
  import { page, navigating } from '$app/state';
  import { onNavigate } from '$app/navigation';
  import { asset } from '$app/paths';
  import { locales, localizeHref, deLocalizeHref } from '$lib/paraglide/runtime';
  import NProgress from 'nprogress';
  import 'nprogress/nprogress.css';
  import './fonts.css';
  import './layout.css';
  import interLatin400 from '@fontsource/inter-tight/files/inter-tight-latin-400-normal.woff2?url';
  import interLatin800 from '@fontsource/inter-tight/files/inter-tight-latin-800-normal.woff2?url';
  import favicon from '$lib/assets/favicon.svg';
  import { absoluteUrl } from '$lib/seo';
  import Nav from '$lib/components/Nav.svelte';
  import Footer from '$lib/components/Footer.svelte';

  NProgress.configure({ showSpinner: false, minimum: 0.12, trickleSpeed: 180, speed: 400 });

  let { children } = $props();

  const withTrailingSlash = (href: string) => (href.endsWith('/') ? href : `${href}/`);

  const canonical = $derived(absoluteUrl(withTrailingSlash(page.url.pathname)));
  const alternates = $derived(
    locales.map((locale) => ({
      locale,
      href: absoluteUrl(
        withTrailingSlash(localizeHref(deLocalizeHref(page.url.pathname), { locale }))
      )
    }))
  );

  $effect(() => {
    if (navigating.to) NProgress.start();
    else NProgress.done();
  });

  onNavigate((navigation) => {
    if (
      typeof document === 'undefined' ||
      !document.startViewTransition ||
      window.matchMedia('(prefers-reduced-motion: reduce)').matches
    ) {
      return;
    }
    return new Promise((resolve) => {
      document.startViewTransition(async () => {
        resolve();
        await navigation.complete;
      });
    });
  });
</script>

<svelte:head>
  <link rel="preload" href={interLatin400} as="font" type="font/woff2" crossorigin="anonymous" />
  <link rel="preload" href={interLatin800} as="font" type="font/woff2" crossorigin="anonymous" />
  <link rel="icon" href={favicon} />
  <link rel="manifest" href={asset('/site.webmanifest')} />
  <meta name="robots" content="index, follow, max-image-preview:large" />
  <link rel="canonical" href={canonical} />
  {#each alternates as alternate (alternate.locale)}
    <link rel="alternate" hreflang={alternate.locale} href={alternate.href} />
  {/each}
</svelte:head>

<div class="flex min-h-screen flex-col bg-background text-foreground">
  <Nav />
  <main class="flex-1">
    {@render children()}
  </main>
  <Footer />
</div>

<div style="display:none">
  {#each locales as locale (locale)}
    <a href={localizeHref(page.url.pathname, { locale })}>{locale}</a>
  {/each}
</div>
