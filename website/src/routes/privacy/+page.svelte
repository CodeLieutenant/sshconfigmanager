<script lang="ts">
  import Badge from '$lib/components/Badge.svelte';
  import Icon from '$lib/components/Icon.svelte';
  import Seo from '$lib/components/Seo.svelte';
  import { CONTACT_EMAIL } from '$lib/links';
  import { formattedPolicyUpdated } from '$lib/policy';
  import * as m from '$lib/paraglide/messages';

  const updated = formattedPolicyUpdated();

  const highlights = $derived([
    { icon: 'cpu', title: m.privacy_hl1_title(), body: m.privacy_hl1_body() },
    { icon: 'github', title: m.privacy_hl2_title(), body: m.privacy_hl2_body() },
    { icon: 'globe', title: m.privacy_hl3_title(), body: m.privacy_hl3_body() }
  ]);

  const sections = $derived([
    { id: 'overview', label: m.privacy_toc_overview() },
    { id: 'app', label: m.privacy_toc_app() },
    { id: 'sync', label: m.privacy_toc_sync() },
    { id: 'website', label: m.privacy_toc_website() },
    { id: 'changes', label: m.privacy_toc_changes() },
    { id: 'contact', label: m.privacy_toc_contact() }
  ]);

  const appItems = $derived([
    m.privacy_app_item1(),
    m.privacy_app_item2(),
    m.privacy_app_item3(),
    m.privacy_app_item4()
  ]);
</script>

<Seo title={m.privacy_seo_title()} description={m.privacy_seo_description()} />

<section class="relative overflow-hidden">
  <div class="bg-grid mask-fade-top absolute inset-0"></div>
  <div
    class="pointer-events-none absolute top-[-12%] left-1/2 h-[440px] w-[760px] -translate-x-1/2 rounded-full bg-primary/12 blur-[130px]"
  ></div>

  <div class="relative mx-auto max-w-[1100px] px-5 pt-20 pb-10 text-center sm:px-8 sm:pt-24">
    <div class="flex justify-center"><Badge dot={false}>{m.privacy_hero_badge()}</Badge></div>
    <h1
      class="text-sheen mx-auto mt-6 max-w-3xl text-4xl font-extrabold tracking-[-0.03em] sm:text-5xl"
    >
      {m.privacy_hero_title()}
    </h1>
    <p class="mx-auto mt-5 max-w-xl text-lg text-muted-foreground">
      {m.privacy_hero_subtitle()}
    </p>
    <p class="mt-4 font-mono text-[13px] text-faint">{m.privacy_last_updated({ date: updated })}</p>
  </div>

  <div class="relative mx-auto max-w-[1100px] px-5 pb-6 sm:px-8">
    <div class="grid gap-4 md:grid-cols-3">
      {#each highlights as h (h.title)}
        <div class="rounded-2xl border border-border-subtle bg-card p-6">
          <div
            class="grid h-11 w-11 place-items-center rounded-xl bg-primary/10 text-primary ring-1 ring-primary/15"
          >
            <Icon name={h.icon} size={20} />
          </div>
          <h3 class="mt-5 text-[16px] font-semibold tracking-tight text-foreground">{h.title}</h3>
          <p class="mt-2 text-[14px] leading-relaxed text-muted-foreground">{h.body}</p>
        </div>
      {/each}
    </div>
  </div>
</section>

<section class="mx-auto max-w-[1100px] px-5 py-16 sm:px-8">
  <div class="lg:grid lg:grid-cols-[220px_1fr] lg:gap-14">
    <aside class="hidden lg:block">
      <nav class="sticky top-24">
        <p class="text-[12px] font-semibold tracking-[0.1em] text-faint uppercase">
          {m.page_toc_heading()}
        </p>
        <ul class="mt-4 space-y-1">
          {#each sections as s (s.id)}
            <li>
              <a
                href={`#${s.id}`}
                class="block rounded-md px-2 py-1.5 text-[14px] text-muted-foreground transition-colors hover:bg-card hover:text-foreground"
                >{s.label}</a
              >
            </li>
          {/each}
        </ul>
      </nav>
    </aside>

    <article class="max-w-[680px] space-y-12">
      <div id="overview" class="scroll-mt-24">
        <h2 class="text-2xl font-bold tracking-tight text-foreground">
          {m.privacy_toc_overview()}
        </h2>
        <p class="mt-4 text-[16px] leading-relaxed text-muted-foreground">
          {m.privacy_overview_p1()}
        </p>
      </div>

      <div id="app" class="scroll-mt-24">
        <h2 class="text-2xl font-bold tracking-tight text-foreground">{m.privacy_toc_app()}</h2>
        <p class="mt-4 text-[16px] leading-relaxed text-muted-foreground">
          {m.privacy_app_intro()}
        </p>
        <ul class="mt-4 space-y-3">
          {#each appItems as item (item)}
            <li class="flex items-start gap-3">
              <span
                class="mt-0.5 grid h-5 w-5 shrink-0 place-items-center rounded-full bg-primary/10 text-primary"
                ><Icon name="check" size={13} /></span
              >
              <span class="text-[15px] text-muted-foreground">{item}</span>
            </li>
          {/each}
        </ul>
        <p class="mt-4 text-[16px] leading-relaxed text-muted-foreground">
          {m.privacy_app_outro()}
        </p>
      </div>

      <div id="sync" class="scroll-mt-24">
        <h2 class="text-2xl font-bold tracking-tight text-foreground">{m.privacy_toc_sync()}</h2>
        <p class="mt-4 text-[16px] leading-relaxed text-muted-foreground">
          {m.privacy_sync_p1()}
        </p>
        <p class="mt-4 text-[16px] leading-relaxed text-muted-foreground">
          {m.privacy_sync_p2()}
        </p>
      </div>

      <div id="website" class="scroll-mt-24">
        <h2 class="text-2xl font-bold tracking-tight text-foreground">
          {m.privacy_toc_website()}
        </h2>
        <p class="mt-4 text-[16px] leading-relaxed text-muted-foreground">
          {m.privacy_website_p1()}
        </p>
        <p class="mt-4 text-[16px] leading-relaxed text-muted-foreground">
          {m.privacy_website_p2()}
        </p>
      </div>

      <div id="changes" class="scroll-mt-24">
        <h2 class="text-2xl font-bold tracking-tight text-foreground">
          {m.privacy_toc_changes()}
        </h2>
        <p class="mt-4 text-[16px] leading-relaxed text-muted-foreground">
          {m.privacy_changes_p1()}
        </p>
      </div>

      <div id="contact" class="scroll-mt-24">
        <h2 class="text-2xl font-bold tracking-tight text-foreground">
          {m.privacy_toc_contact()}
        </h2>
        <p class="mt-4 text-[16px] leading-relaxed text-muted-foreground">
          {m.privacy_contact_pre()}
          <a
            href={`mailto:${CONTACT_EMAIL}`}
            class="text-primary underline-offset-2 hover:underline">{CONTACT_EMAIL}</a
          >.
        </p>
        <a
          href={`mailto:${CONTACT_EMAIL}`}
          class="mt-5 inline-flex items-center gap-2 rounded-[10px] border border-border bg-card px-4 py-2.5 text-[15px] font-medium text-foreground transition-colors hover:border-border-strong hover:bg-elevated"
        >
          <Icon name="mail" size={16} class="text-primary" />
          {m.privacy_contact_cta()}
        </a>
      </div>
    </article>
  </div>
</section>
