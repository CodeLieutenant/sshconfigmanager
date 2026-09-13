<script lang="ts">
  import Badge from '$lib/components/Badge.svelte';
  import Icon from '$lib/components/Icon.svelte';
  import Seo from '$lib/components/Seo.svelte';
  import { APPLE_STANDARD_EULA_URL, CONTACT_EMAIL, LICENSE_URL } from '$lib/links';
  import { formattedPolicyUpdated } from '$lib/policy';
  import * as m from '$lib/paraglide/messages';

  const updated = formattedPolicyUpdated();

  const highlights = $derived([
    { icon: 'branch', title: m.terms_hl1_title(), body: m.terms_hl1_body() },
    { icon: 'info', title: m.terms_hl2_title(), body: m.terms_hl2_body() },
    { icon: 'apple', title: m.terms_hl3_title(), body: m.terms_hl3_body() }
  ]);

  const sections = $derived([
    { id: 'license', label: m.terms_toc_license() },
    { id: 'warranty', label: m.terms_toc_warranty() },
    { id: 'liability', label: m.terms_toc_liability() },
    { id: 'app-store', label: m.terms_toc_appstore() },
    { id: 'third-party', label: m.terms_toc_oss() },
    { id: 'changes', label: m.terms_toc_changes() },
    { id: 'contact', label: m.terms_toc_contact() }
  ]);
</script>

<Seo title={m.terms_seo_title()} description={m.terms_seo_description()} />

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
      {m.terms_hero_title()}
    </h1>
    <p class="mx-auto mt-5 max-w-xl text-lg text-muted-foreground">
      {m.terms_hero_subtitle()}
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
      <div id="license" class="scroll-mt-24">
        <h2 class="text-2xl font-bold tracking-tight text-foreground">
          1. {m.terms_toc_license()}
        </h2>
        <p class="mt-4 text-[16px] leading-relaxed text-muted-foreground">
          {m.terms_license_p1()}
        </p>
        <a
          href={LICENSE_URL}
          rel="noreferrer"
          class="mt-4 inline-flex items-center gap-1.5 text-[15px] font-medium text-primary hover:underline"
        >
          {m.terms_license_link()}
          <Icon name="arrow" size={14} />
        </a>
      </div>

      <div id="warranty" class="scroll-mt-24">
        <h2 class="text-2xl font-bold tracking-tight text-foreground">
          2. {m.terms_toc_warranty()}
        </h2>
        <p class="mt-4 text-[16px] leading-relaxed text-muted-foreground">
          {m.terms_warranty_p1()}
        </p>
      </div>

      <div id="liability" class="scroll-mt-24">
        <h2 class="text-2xl font-bold tracking-tight text-foreground">
          3. {m.terms_toc_liability()}
        </h2>
        <p class="mt-4 text-[16px] leading-relaxed text-muted-foreground">
          {m.terms_liability_p1()}
        </p>
      </div>

      <div id="app-store" class="scroll-mt-24">
        <h2 class="text-2xl font-bold tracking-tight text-foreground">
          4. {m.terms_toc_appstore()}
        </h2>
        <p class="mt-4 text-[16px] leading-relaxed text-muted-foreground">
          {m.terms_appstore_p1()}
        </p>
        <a
          href={APPLE_STANDARD_EULA_URL}
          rel="noreferrer"
          class="mt-4 inline-flex items-center gap-1.5 text-[15px] font-medium text-primary hover:underline"
        >
          {m.terms_appstore_link()}
          <Icon name="arrow" size={14} />
        </a>
      </div>

      <div id="third-party" class="scroll-mt-24">
        <h2 class="text-2xl font-bold tracking-tight text-foreground">5. {m.terms_toc_oss()}</h2>
        <p class="mt-4 text-[16px] leading-relaxed text-muted-foreground">
          {m.terms_oss_p1()}
        </p>
      </div>

      <div id="changes" class="scroll-mt-24">
        <h2 class="text-2xl font-bold tracking-tight text-foreground">
          6. {m.terms_toc_changes()}
        </h2>
        <p class="mt-4 text-[16px] leading-relaxed text-muted-foreground">
          {m.terms_changes_p1()}
        </p>
      </div>

      <div id="contact" class="scroll-mt-24">
        <h2 class="text-2xl font-bold tracking-tight text-foreground">
          7. {m.terms_toc_contact()}
        </h2>
        <p class="mt-4 text-[16px] leading-relaxed text-muted-foreground">
          {m.terms_contact_p1()}
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
