<script lang="ts">
  import { page } from '$app/state';
  import { locales, localizeHref, extractLocaleFromUrl, setLocale } from '$lib/paraglide/runtime';
  import type { Locale } from '$lib/paraglide/runtime';
  import Icon from './Icon.svelte';

  const LOCALE_LABELS: Record<string, string> = {
    en: 'English',
    nl: 'Nederlands',
    de: 'Deutsch',
    el: 'Ελληνικά'
  };

  const currentLocale = $derived(extractLocaleFromUrl(page.url.href));

  let open = $state(false);

  function close() {
    open = false;
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape' && open) close();
  }

  function selectLocale(e: MouseEvent, locale: Locale) {
    e.preventDefault();
    close();
    setLocale(locale);
  }
</script>

<svelte:window onkeydown={handleKeydown} />

<div class="relative">
  <button
    type="button"
    onclick={() => (open = !open)}
    aria-haspopup="listbox"
    aria-expanded={open}
    aria-label="Change language"
    class="flex h-9 items-center gap-1.5 rounded-lg border border-border px-2.5 text-[13px] font-medium text-muted-foreground transition-colors hover:border-border-strong hover:bg-card hover:text-foreground"
  >
    <Icon name="globe" size={15} />
    <span class="uppercase">{currentLocale}</span>
    <Icon
      name="chevron"
      size={13}
      class="transition-transform duration-200 {open ? '-rotate-90' : 'rotate-90'}"
    />
  </button>

  {#if open}
    <button
      type="button"
      aria-label="Close language menu"
      onclick={close}
      class="fixed inset-0 z-40 cursor-default"
    ></button>
    <div
      role="listbox"
      aria-label="Select language"
      class="ring-hairline absolute right-0 z-50 mt-2 w-40 overflow-hidden rounded-xl border border-border bg-surface p-1 shadow-2xl"
    >
      {#each locales as locale (locale)}
        <a
          href={localizeHref(page.url.pathname + page.url.search, { locale })}
          role="option"
          aria-selected={locale === currentLocale}
          onclick={(e) => selectLocale(e, locale)}
          class="flex items-center justify-between gap-2 rounded-lg px-3 py-2 text-[13.5px] transition-colors {locale ===
          currentLocale
            ? 'bg-primary/8 font-medium text-foreground'
            : 'text-muted-foreground hover:bg-card hover:text-foreground'}"
        >
          {LOCALE_LABELS[locale] ?? locale}
          {#if locale === currentLocale}
            <Icon name="check" size={14} class="text-primary" />
          {/if}
        </a>
      {/each}
    </div>
  {/if}
</div>
