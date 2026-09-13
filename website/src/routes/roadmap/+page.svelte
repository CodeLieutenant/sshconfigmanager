<script lang="ts">
  import Badge from '$lib/components/Badge.svelte';
  import Button from '$lib/components/Button.svelte';
  import Icon from '$lib/components/Icon.svelte';
  import Seo from '$lib/components/Seo.svelte';
  import { breadcrumbLd } from '$lib/seo';
  import { GITHUB_ISSUES, GITHUB_RELEASES } from '$lib/links';
  import * as m from '$lib/paraglide/messages';

  const COLUMNS = $derived([
    { key: 'now', label: m.roadmap_col_now_label(), hint: m.roadmap_col_now_hint(), icon: 'bolt' },
    {
      key: 'next',
      label: m.roadmap_col_next_label(),
      hint: m.roadmap_col_next_hint(),
      icon: 'route'
    },
    {
      key: 'later',
      label: m.roadmap_col_later_label(),
      hint: m.roadmap_col_later_hint(),
      icon: 'layers'
    }
  ]);

  type Item = { title: string; text: string; tag?: string };

  const columns: Record<string, Item[]> = $derived({
    now: [{ title: m.roadmap_now1_title(), text: m.roadmap_now1_text() }],
    next: [
      { title: m.roadmap_next1_title(), text: m.roadmap_next1_text() },
      { title: m.roadmap_next2_title(), text: m.roadmap_next2_text() },
      { title: m.roadmap_next3_title(), text: m.roadmap_next3_text() },
      { title: m.roadmap_next4_title(), text: m.roadmap_next4_text() }
    ],
    later: [
      { title: m.roadmap_later1_title(), text: m.roadmap_later1_text() },
      { title: m.roadmap_later2_title(), text: m.roadmap_later2_text() },
      { title: m.roadmap_later3_title(), text: m.roadmap_later3_text() },
      { title: m.roadmap_later4_title(), text: m.roadmap_later4_text() }
    ]
  });

  const shipped: Item[] = $derived([
    { title: m.roadmap_shipped1_title(), text: m.roadmap_shipped1_text(), tag: 'Linux' },
    { title: m.roadmap_shipped2_title(), text: m.roadmap_shipped2_text() },
    { title: m.roadmap_shipped3_title(), text: m.roadmap_shipped3_text() },
    { title: m.roadmap_shipped4_title(), text: m.roadmap_shipped4_text() },
    { title: m.roadmap_shipped5_title(), text: m.roadmap_shipped5_text() },
    { title: m.roadmap_shipped6_title(), text: m.roadmap_shipped6_text() },
    { title: m.roadmap_shipped7_title(), text: m.roadmap_shipped7_text() },
    { title: m.roadmap_shipped8_title(), text: m.roadmap_shipped8_text() },
    { title: m.roadmap_shipped9_title(), text: m.roadmap_shipped9_text() }
  ]);

  const columnItems = (key: string): Item[] => columns[key] ?? [];

  const jsonLd = $derived([
    breadcrumbLd([
      { name: m.breadcrumb_home(), path: '/' },
      { name: m.nav_roadmap(), path: '/roadmap' }
    ])
  ]);
</script>

<Seo
  title={m.roadmap_seo_title()}
  description={m.roadmap_seo_description()}
  canonicalPath="/roadmap"
  {jsonLd}
/>

<section class="relative overflow-hidden border-b border-border-subtle">
  <div class="bg-grid mask-fade-top absolute inset-0"></div>
  <div
    class="pointer-events-none absolute top-[-30%] left-1/2 h-[440px] w-[760px] -translate-x-1/2 rounded-full bg-primary/12 blur-[120px]"
  ></div>
  <div class="relative mx-auto max-w-[1200px] px-5 py-20 text-center sm:px-8 sm:py-24">
    <div class="flex justify-center"><Badge>{m.nav_roadmap()}</Badge></div>
    <h1
      class="text-sheen mx-auto mt-6 max-w-2xl text-4xl font-extrabold tracking-[-0.03em] sm:text-5xl"
    >
      {m.roadmap_hero_title()}
    </h1>
    <p class="mx-auto mt-5 max-w-xl text-lg text-muted-foreground">
      {m.roadmap_hero_subtitle()}
    </p>
    <div class="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
      <Button href={GITHUB_ISSUES} size="lg"
        ><Icon name="message" size={17} /> {m.roadmap_hero_request_feature()}</Button
      >
      <Button href={GITHUB_RELEASES} variant="secondary" size="lg"
        >{m.roadmap_hero_see_shipped()}</Button
      >
    </div>
  </div>
</section>

<section>
  <div class="mx-auto max-w-[1200px] px-5 py-20 sm:px-8 sm:py-24">
    <div class="grid gap-5 lg:grid-cols-3">
      {#each COLUMNS as col (col.key)}
        <div class="flex flex-col rounded-2xl border border-border-subtle bg-card p-6">
          <div class="flex items-center gap-3">
            <span
              class="grid h-10 w-10 place-items-center rounded-xl bg-primary/10 text-primary ring-1 ring-primary/15"
              ><Icon name={col.icon} size={18} /></span
            >
            <div>
              <h2 class="text-[17px] font-semibold tracking-tight text-foreground">{col.label}</h2>
              <p class="text-[12px] text-faint">{col.hint}</p>
            </div>
          </div>

          <ul class="mt-6 space-y-4">
            {#each columnItems(col.key) as item (item.title)}
              <li class="rounded-xl border border-border-subtle bg-background/40 p-4">
                <div class="flex flex-wrap items-center gap-2">
                  <h3 class="text-[15px] font-semibold tracking-tight text-foreground">
                    {item.title}
                  </h3>
                  {#if item.tag}
                    <span
                      class="rounded-full bg-secondary px-2 py-0.5 text-[10px] font-semibold tracking-wide text-muted-foreground uppercase"
                      >{item.tag}</span
                    >
                  {/if}
                </div>
                <p class="mt-1.5 text-[13px] leading-relaxed text-muted-foreground">{item.text}</p>
              </li>
            {/each}
          </ul>
        </div>
      {/each}
    </div>
  </div>
</section>

<section class="border-y border-border-subtle bg-surface">
  <div class="mx-auto max-w-[1200px] px-5 py-20 sm:px-8 sm:py-24">
    <div class="flex items-center gap-2">
      <Icon name="check" size={18} class="text-primary" />
      <h2 class="text-2xl font-bold tracking-[-0.02em] text-foreground sm:text-3xl">
        {m.roadmap_shipped_title()}
      </h2>
    </div>
    <p class="mt-3 max-w-xl text-[15px] text-muted-foreground">
      {m.roadmap_shipped_subtitle()}
    </p>
    <div class="mt-10 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      {#each shipped as item (item.title)}
        <div class="flex gap-3.5 rounded-2xl border border-border-subtle bg-card p-5">
          <span
            class="mt-0.5 grid h-7 w-7 shrink-0 place-items-center rounded-lg bg-primary/10 text-primary"
            ><Icon name="check" size={15} /></span
          >
          <div>
            <div class="flex flex-wrap items-center gap-2">
              <h3 class="text-[15px] font-semibold tracking-tight text-foreground">
                {item.title}
              </h3>
              {#if item.tag}
                <span
                  class="rounded-full bg-secondary px-2 py-0.5 text-[10px] font-semibold tracking-wide text-muted-foreground uppercase"
                  >{item.tag}</span
                >
              {/if}
            </div>
            <p class="mt-1 text-[13px] leading-relaxed text-muted-foreground">{item.text}</p>
          </div>
        </div>
      {/each}
    </div>
    <div class="mt-8">
      <Button href={GITHUB_RELEASES} variant="secondary">{m.roadmap_shipped_release_notes()}</Button
      >
    </div>
  </div>
</section>

<section class="relative overflow-hidden">
  <div
    class="pointer-events-none absolute bottom-[-40%] left-1/2 h-[460px] w-[760px] -translate-x-1/2 rounded-full bg-primary/15 blur-[120px]"
  ></div>
  <div class="relative mx-auto max-w-[1200px] px-5 py-24 text-center sm:px-8">
    <h2 class="mx-auto max-w-2xl text-3xl font-bold tracking-[-0.02em] text-foreground sm:text-4xl">
      {m.roadmap_cta_title()}
    </h2>
    <p class="mx-auto mt-4 max-w-xl text-lg text-muted-foreground">
      {m.roadmap_cta_subtitle()}
    </p>
    <div class="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
      <Button href={GITHUB_ISSUES} size="lg"
        ><Icon name="send" size={16} /> {m.roadmap_cta_send_idea()}</Button
      >
      <Button href={GITHUB_RELEASES} variant="secondary" size="lg"
        >{m.nav_download_release()}</Button
      >
    </div>
  </div>
</section>
