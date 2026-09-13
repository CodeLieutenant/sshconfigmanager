<script lang="ts">
  import { page } from '$app/state';
  import Logo from './Logo.svelte';
  import Button from './Button.svelte';
  import Icon from './Icon.svelte';
  import LanguagePicker from './LanguagePicker.svelte';
  import { GITHUB_REPO, GITHUB_RELEASES } from '$lib/links';
  import { localizeHref, deLocalizeHref } from '$lib/paraglide/runtime';
  import * as m from '$lib/paraglide/messages';

  const links = $derived([
    { label: m.nav_roadmap(), href: '/roadmap' },
    { label: m.nav_privacy(), href: '/privacy' },
    { label: m.nav_terms(), href: '/terms' }
  ]);

  let open = $state(false);

  const isActive = (href: string) => {
    const currentPath = deLocalizeHref(page.url.pathname).replace(/\/$/, '') || '/';
    return href === '/' ? currentPath === '/' : currentPath.startsWith(href);
  };
</script>

<header class="sticky top-0 z-50 border-b border-border-subtle bg-background/70 backdrop-blur-xl">
  <nav class="mx-auto flex h-16 max-w-[1200px] items-center justify-between px-5 sm:px-8">
    <Logo />

    <div class="hidden items-center gap-6 lg:flex">
      {#each links as link (link.href)}
        <a
          href={localizeHref(link.href)}
          class="relative pb-[3px] text-[14.5px] tracking-tight transition-colors {isActive(
            link.href
          )
            ? 'text-foreground'
            : 'text-muted-foreground hover:text-foreground'}"
        >
          {link.label}
          {#if isActive(link.href)}
            <span class="absolute right-0 bottom-0 left-0 h-[2px] rounded-full bg-primary"></span>
          {/if}
        </a>
      {/each}
      <a
        href={GITHUB_REPO}
        rel="noreferrer"
        class="pb-[3px] text-[14.5px] tracking-tight text-muted-foreground transition-colors hover:text-foreground"
      >
        GitHub
      </a>
    </div>

    <div class="hidden items-center gap-3 lg:flex">
      <LanguagePicker />
      <Button href={GITHUB_RELEASES} size="sm">{m.nav_download_release()}</Button>
    </div>

    <button
      class="grid h-10 w-10 cursor-pointer place-items-center rounded-lg border border-border text-foreground transition-colors hover:bg-card lg:hidden"
      aria-label={open ? m.nav_close_menu() : m.nav_open_menu()}
      aria-expanded={open}
      onclick={() => (open = !open)}
    >
      <Icon name={open ? 'x' : 'layers'} size={18} />
    </button>
  </nav>

  {#if open}
    <div class="border-t border-border-subtle bg-background px-5 py-4 lg:hidden">
      <div class="flex flex-col gap-0.5">
        {#each links as link (link.href)}
          <a
            href={localizeHref(link.href)}
            onclick={() => (open = false)}
            class="flex items-center gap-2 rounded-lg px-3 py-2.5 text-[15px] transition-colors {isActive(
              link.href
            )
              ? 'bg-primary/8 font-medium text-foreground'
              : 'text-muted-foreground hover:bg-card hover:text-foreground'}"
          >
            <span
              class="h-1.5 w-1.5 shrink-0 rounded-full {isActive(link.href)
                ? 'bg-primary'
                : 'bg-transparent'}"
            ></span>
            {link.label}
          </a>
        {/each}
        <a
          href={GITHUB_REPO}
          rel="noreferrer"
          onclick={() => (open = false)}
          class="flex items-center gap-2 rounded-lg px-3 py-2.5 text-[15px] text-muted-foreground transition-colors hover:bg-card hover:text-foreground"
        >
          <span class="h-1.5 w-1.5 shrink-0 rounded-full bg-transparent"></span>
          GitHub
        </a>
        <Button href={GITHUB_RELEASES} class="mt-2 w-full">{m.nav_download_release()}</Button>
        <div class="mt-3 flex justify-center">
          <LanguagePicker />
        </div>
      </div>
    </div>
  {/if}
</header>
