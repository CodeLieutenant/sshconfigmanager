<script lang="ts">
  import { asset } from '$app/paths';
  import Button from '$lib/components/Button.svelte';
  import FeatureCard from '$lib/components/FeatureCard.svelte';
  import Icon from '$lib/components/Icon.svelte';
  import Screenshot from '$lib/components/Screenshot.svelte';
  import Seo from '$lib/components/Seo.svelte';
  import Terminal from '$lib/components/Terminal.svelte';
  import * as m from '$lib/paraglide/messages';
  import { localizeHref } from '$lib/paraglide/runtime';
  import { APP_STORE_URL } from '$lib/appstore';
  import {
    APP_STORE_PRICE,
    GITHUB_REPO,
    GITHUB_RELEASES,
    GITHUB_SPONSORS,
    LINUX_DEB_URL,
    LINUX_FLATPAK_URL,
    LINUX_RPM_URL
  } from '$lib/links';
  import { organizationLd, softwareApplicationLd, websiteLd } from '$lib/seo';

  const priceLabel = APP_STORE_PRICE.display;

  const jsonLd = [softwareApplicationLd(), organizationLd(), websiteLd()];

  const stats = $derived([
    { v: 'In-process', k: m.home_stat_inprocess_k() },
    { v: '-L · -R · -D', k: m.home_stat_forwards_k() },
    { v: 'ProxyJump', k: m.home_stat_proxyjump_k() },
    { v: 'Apache 2.0', k: m.home_stat_license_k() }
  ]);

  const features = $derived([
    { icon: 'file', title: m.home_feat1_title(), description: m.home_feat1_desc() },
    { icon: 'route', title: m.home_feat2_title(), description: m.home_feat2_desc() },
    { icon: 'key', title: m.home_feat3_title(), description: m.home_feat3_desc() },
    { icon: 'shield', title: m.home_feat4_title(), description: m.home_feat4_desc() },
    { icon: 'history', title: m.home_feat5_title(), description: m.home_feat5_desc() },
    { icon: 'branch', title: m.home_feat6_title(), description: m.home_feat6_desc() }
  ]);

  const losslessPoints = $derived([m.home_lossless1(), m.home_lossless2(), m.home_lossless3()]);

  const forwards = [
    { flag: '-L', path: 'localhost:5432 → 10.0.4.12:5432', label: m.home_forward_local_label() },
    { flag: '-R', path: 'bastion:8080 → localhost:3000', label: m.home_forward_remote_label() },
    { flag: '-D', path: 'SOCKS5 proxy on :1080', label: m.home_forward_dynamic_label() }
  ];

  const security = $derived([
    { icon: 'lock', title: m.home_sec1_title(), description: m.home_sec1_desc() },
    { icon: 'cpu', title: m.home_sec2_title(), description: m.home_sec2_desc() },
    { icon: 'fingerprint', title: m.home_sec3_title(), description: m.home_sec3_desc() }
  ]);

  const linuxPackages = $derived([
    { label: m.home_download_deb(), detail: m.home_download_arch(), href: LINUX_DEB_URL },
    { label: m.home_download_rpm(), detail: m.home_download_arch(), href: LINUX_RPM_URL },
    { label: m.home_download_flatpak(), detail: 'Flatpak', href: LINUX_FLATPAK_URL }
  ]);

  const supportOptions = $derived([
    {
      icon: 'apple',
      title: m.home_support_appstore_title({ price: priceLabel }),
      description: m.home_support_appstore_desc({ price: priceLabel }),
      cta: m.home_support_appstore_cta(),
      href: APP_STORE_URL
    },
    {
      icon: 'star',
      title: m.home_support_sponsor_title(),
      description: m.home_support_sponsor_desc(),
      cta: m.home_support_sponsor_cta(),
      href: GITHUB_SPONSORS
    },
    {
      icon: 'branch',
      title: m.home_support_contribute_title(),
      description: m.home_support_contribute_desc(),
      cta: m.home_support_contribute_cta(),
      href: GITHUB_REPO
    }
  ]);
</script>

<Seo
  title={m.home_seo_title_oss()}
  description={m.home_seo_description_oss()}
  canonicalPath="/"
  {jsonLd}
/>

<svelte:head>
  <link
    rel="preload"
    as="image"
    type="image/avif"
    imagesrcset="{asset('/screenshots/01-host-detail-720.avif')} 720w, {asset(
      '/screenshots/01-host-detail-1440.avif'
    )} 1440w"
    imagesizes="(min-width: 1024px) 640px, 92vw"
  />
</svelte:head>

<section class="relative overflow-hidden">
  <div class="bg-grid mask-fade-top absolute inset-0"></div>

  <div
    class="relative mx-auto grid max-w-[1200px] items-center gap-12 px-5 pt-20 pb-16 sm:px-8 sm:pt-28 lg:grid-cols-[2fr_3fr] lg:gap-16 lg:pb-24"
  >
    <div class="flex flex-col items-start">
      <div
        class="mb-6 inline-flex items-center gap-2 rounded-full border border-primary/30 bg-primary/8 px-3 py-1 text-[13px] font-medium text-primary"
      >
        {m.home_hero_badge_oss()}
      </div>

      <h1 class="hero-title text-sheen">
        {m.home_hero_title_l1()}<br />{m.home_hero_title_l2_oss()}
      </h1>

      <p class="mt-5 text-lg leading-relaxed text-muted-foreground">
        {m.home_hero_subtitle_oss()}
      </p>

      <div class="mt-8 flex flex-col gap-3 sm:flex-row">
        <Button href={GITHUB_RELEASES} size="lg" class="w-full sm:w-auto">
          <Icon name="arrow" size={17} />
          {m.nav_download_release()}
        </Button>
        <Button href={GITHUB_REPO} variant="secondary" size="lg" class="w-full sm:w-auto">
          {m.home_hero_view_source()}
        </Button>
      </div>

      <div class="mt-6 flex flex-wrap gap-x-5 gap-y-2 text-[13px] text-faint">
        <span class="inline-flex items-center gap-1.5">
          <Icon name="check" size={13} class="text-primary" />
          {m.home_hero_check_free()}
        </span>
        <span class="inline-flex items-center gap-1.5">
          <Icon name="check" size={13} class="text-primary" />
          {m.home_hero_check_tunnels()}
        </span>
        <span class="inline-flex items-center gap-1.5">
          <Icon name="check" size={13} class="text-primary" /> ProxyJump
        </span>
        <span class="inline-flex items-center gap-1.5">
          <Icon name="check" size={13} class="text-primary" />
          {m.home_hero_check_platforms()}
        </span>
      </div>
    </div>

    <div class="relative flex items-center justify-center">
      <div
        class="pointer-events-none absolute inset-0 -z-10 rounded-full bg-primary/12 blur-[100px]"
      ></div>
      <Screenshot
        name="01-host-detail"
        alt="SSH Config Manager — host detail view showing the glass sidebar and card layout"
        class="app-frame w-full"
        priority
      />
    </div>
  </div>
</section>

<section class="border-y border-border-subtle bg-surface">
  <div class="mx-auto grid max-w-[1200px] grid-cols-2 sm:grid-cols-4">
    {#each stats as s, i (s.v)}
      <div
        class={`px-6 py-7 ${i > 0 ? 'border-border-subtle sm:border-l' : ''} ${i % 2 === 1 ? 'border-l border-border-subtle sm:border-l' : ''} ${i >= 2 ? 'border-t border-border-subtle sm:border-t-0' : ''}`}
      >
        <div class="font-mono text-lg font-semibold tracking-tight text-foreground">{s.v}</div>
        <div class="mt-1 text-[13px] text-faint">{s.k}</div>
      </div>
    {/each}
  </div>
</section>

<section class="mx-auto max-w-[1200px] px-5 py-24 sm:px-8 sm:py-28">
  <div class="max-w-2xl">
    <p class="text-[13px] font-semibold tracking-[0.12em] text-primary uppercase">
      {m.home_features_eyebrow()}
    </p>
    <h2 class="mt-3 text-3xl font-bold tracking-[-0.02em] text-foreground sm:text-4xl">
      {m.home_features_title()}
    </h2>
    <p class="mt-4 text-lg text-muted-foreground">
      {m.home_features_subtitle()}
    </p>
  </div>

  <div class="mt-12 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
    {#each features as f (f.title)}
      <FeatureCard icon={f.icon} title={f.title} description={f.description} />
    {/each}
  </div>
</section>

<section class="border-t border-border-subtle bg-surface">
  <div
    class="mx-auto grid max-w-[1200px] items-center gap-12 px-5 py-24 sm:px-8 lg:grid-cols-2 lg:gap-16"
  >
    <div>
      <div
        class="inline-flex items-center gap-2 rounded-full border border-border bg-card px-3 py-1 text-[13px] text-muted-foreground"
      >
        <Icon name="file" size={14} class="text-primary" />
        {m.home_config_badge()}
      </div>
      <h2 class="mt-5 text-3xl font-bold tracking-[-0.02em] text-foreground sm:text-[34px]">
        {m.home_config_title_pre()} <code class="font-mono text-primary">ssh_config</code>
        {m.home_config_title_post()}
      </h2>
      <p class="mt-4 text-lg text-muted-foreground">
        {m.home_config_desc()}
      </p>
      <ul class="mt-7 space-y-3">
        {#each losslessPoints as point (point)}
          <li class="flex items-start gap-3">
            <span
              class="mt-0.5 grid h-5 w-5 shrink-0 place-items-center rounded-full bg-primary/10 text-primary"
            >
              <Icon name="check" size={13} />
            </span>
            <span class="text-[15px] text-muted-foreground">{point}</span>
          </li>
        {/each}
      </ul>
    </div>
    <Terminal />
  </div>
</section>

<section class="border-t border-border-subtle">
  <div
    class="mx-auto grid max-w-[1200px] items-center gap-12 px-5 py-24 sm:px-8 lg:grid-cols-2 lg:gap-16"
  >
    <div class="order-2 lg:order-1">
      <div class="ring-hairline rounded-2xl border border-border bg-card p-6 shadow-2xl">
        <div class="mb-4 flex items-center justify-between">
          <span class="text-[13px] font-medium text-muted-foreground"
            >{m.home_tunnels_card_label()}</span
          >
          <span
            class="inline-flex items-center gap-1.5 rounded-full bg-primary/10 px-2 py-0.5 text-[11px] text-primary"
          >
            <span class="h-1.5 w-1.5 rounded-full bg-primary"></span>
            {m.home_tunnels_card_badge()}
          </span>
        </div>
        <div class="space-y-2.5">
          {#each forwards as fwd (fwd.flag)}
            <div
              class="flex items-center gap-3 rounded-xl border border-border-subtle bg-background/50 p-3"
            >
              <span
                class="grid h-9 w-11 shrink-0 place-items-center rounded-lg bg-primary/10 font-mono text-[13px] font-semibold text-primary"
              >
                {fwd.flag}
              </span>
              <div class="min-w-0">
                <div class="truncate font-mono text-[13px] text-foreground">{fwd.path}</div>
                <div class="text-[12px] text-faint">{fwd.label}</div>
              </div>
            </div>
          {/each}
        </div>
        <div class="mt-4 flex items-center justify-between border-t border-border-subtle pt-4">
          <span class="text-[12px] text-faint">prod-db · via bastion</span>
          <span class="font-mono text-[12px] text-primary">↑ 12.4 · ↓ 3.1 MB/s</span>
        </div>
      </div>
    </div>

    <div class="order-1 lg:order-2">
      <div
        class="inline-flex items-center gap-2 rounded-full border border-border bg-card px-3 py-1 text-[13px] text-muted-foreground"
      >
        <Icon name="route" size={14} class="text-primary" />
        {m.home_tunnels_badge()}
      </div>
      <h2 class="mt-5 text-3xl font-bold tracking-[-0.02em] text-foreground sm:text-[34px]">
        {m.home_tunnels_title()}
      </h2>
      <p class="mt-4 text-lg text-muted-foreground">
        {m.home_tunnels_desc()}
      </p>
      <div class="mt-7 grid grid-cols-2 gap-3">
        <div class="rounded-xl border border-border-subtle bg-card p-4">
          <Icon name="layers" size={18} class="text-primary" />
          <div class="mt-2 text-[14px] font-semibold text-foreground">
            {m.home_tunnels_many_title()}
          </div>
          <div class="mt-1 text-[13px] text-faint">{m.home_tunnels_many_desc()}</div>
        </div>
        <div class="rounded-xl border border-border-subtle bg-card p-4">
          <Icon name="gauge" size={18} class="text-primary" />
          <div class="mt-2 text-[14px] font-semibold text-foreground">
            {m.home_tunnels_throughput_title()}
          </div>
          <div class="mt-1 text-[13px] text-faint">{m.home_tunnels_throughput_desc()}</div>
        </div>
      </div>
    </div>
  </div>
</section>

<section id="security" class="scroll-mt-20 border-t border-border-subtle bg-surface">
  <div class="mx-auto max-w-[1200px] px-5 py-24 sm:px-8 sm:py-28">
    <div class="max-w-2xl">
      <p class="text-[13px] font-semibold tracking-[0.12em] text-primary uppercase">
        {m.home_security_eyebrow()}
      </p>
      <h2 class="mt-3 text-3xl font-bold tracking-[-0.02em] text-foreground sm:text-4xl">
        {m.home_security_title()}
      </h2>
      <p class="mt-4 text-lg text-muted-foreground">
        {m.home_security_subtitle()}
      </p>
    </div>

    <div class="mt-12 grid gap-4 md:grid-cols-3">
      {#each security as item (item.title)}
        <div class="relative overflow-hidden rounded-2xl border border-border-subtle bg-card p-6">
          <div
            class="grid h-11 w-11 place-items-center rounded-xl bg-primary/10 text-primary ring-1 ring-primary/15"
          >
            <Icon name={item.icon} size={20} />
          </div>
          <h3 class="mt-5 text-[18px] font-semibold tracking-tight text-foreground">
            {item.title}
          </h3>
          <p class="mt-2 text-[15px] leading-relaxed text-muted-foreground">{item.description}</p>
        </div>
      {/each}
    </div>
  </div>
</section>

<section id="download" class="scroll-mt-20 border-t border-border-subtle">
  <div class="mx-auto max-w-[1200px] px-5 py-24 sm:px-8 sm:py-28">
    <div class="max-w-2xl">
      <p class="text-[13px] font-semibold tracking-[0.12em] text-primary uppercase">
        {m.home_download_eyebrow()}
      </p>
      <h2 class="mt-3 text-3xl font-bold tracking-[-0.02em] text-foreground sm:text-4xl">
        {m.home_download_title()}
      </h2>
      <p class="mt-4 text-lg text-muted-foreground">
        {m.home_download_desc()}
      </p>
    </div>

    <div class="mt-12 grid gap-4 md:grid-cols-2">
      <div class="flex flex-col rounded-2xl border border-border-subtle bg-card p-6">
        <div
          class="grid h-11 w-11 place-items-center rounded-xl bg-primary/10 text-primary ring-1 ring-primary/15"
        >
          <Icon name="apple" size={20} />
        </div>
        <h3 class="mt-5 text-[18px] font-semibold tracking-tight text-foreground">
          {m.home_download_macos_title()}
        </h3>
        <p class="mt-2 flex-1 text-[15px] leading-relaxed text-muted-foreground">
          {m.home_download_macos_desc()}
        </p>
        <div class="mt-6 flex flex-col gap-3 sm:flex-row">
          <Button href={APP_STORE_URL} class="w-full sm:w-auto">
            <Icon name="apple" size={16} />
            {m.home_download_appstore_cta()}
          </Button>
          <Button href={GITHUB_RELEASES} variant="secondary" class="w-full sm:w-auto">
            <Icon name="github" size={16} />
            {m.home_download_github_cta()}
          </Button>
        </div>
      </div>

      <div class="flex flex-col rounded-2xl border border-border-subtle bg-card p-6">
        <div
          class="grid h-11 w-11 place-items-center rounded-xl bg-primary/10 text-primary ring-1 ring-primary/15"
        >
          <Icon name="terminal" size={20} />
        </div>
        <h3 class="mt-5 text-[18px] font-semibold tracking-tight text-foreground">
          {m.home_download_linux_title()}
        </h3>
        <p class="mt-2 text-[15px] leading-relaxed text-muted-foreground">
          {m.home_download_linux_desc()}
        </p>
        <ul class="mt-5 space-y-2.5">
          {#each linuxPackages as pkg (pkg.label)}
            <li>
              <a
                href={pkg.href}
                rel="noreferrer"
                class="flex items-center justify-between gap-3 rounded-xl border border-border-subtle bg-background/50 p-3 transition-colors hover:border-border-strong"
              >
                <span class="flex min-w-0 items-center gap-3">
                  <Icon name="download" size={16} class="shrink-0 text-primary" />
                  <span class="truncate text-[14px] font-medium text-foreground">{pkg.label}</span>
                </span>
                <span class="shrink-0 font-mono text-[12px] text-faint">{pkg.detail}</span>
              </a>
            </li>
          {/each}
        </ul>
        <p class="mt-4 text-[13px] text-faint">{m.home_download_linux_note()}</p>
      </div>
    </div>
  </div>
</section>

<section id="support" class="scroll-mt-20 border-t border-border-subtle">
  <div class="mx-auto max-w-[1200px] px-5 py-24 sm:px-8 sm:py-28">
    <div class="max-w-2xl">
      <p class="text-[13px] font-semibold tracking-[0.12em] text-primary uppercase">
        {m.home_support_eyebrow()}
      </p>
      <h2 class="mt-3 text-3xl font-bold tracking-[-0.02em] text-foreground sm:text-4xl">
        {m.home_support_title()}
      </h2>
      <p class="mt-4 text-lg text-muted-foreground">
        {m.home_support_desc()}
      </p>
    </div>

    <div class="mt-12 grid gap-4 md:grid-cols-3">
      {#each supportOptions as option (option.title)}
        <div class="flex flex-col rounded-2xl border border-border-subtle bg-card p-6">
          <div
            class="grid h-11 w-11 place-items-center rounded-xl bg-primary/10 text-primary ring-1 ring-primary/15"
          >
            <Icon name={option.icon} size={20} />
          </div>
          <h3 class="mt-5 text-[18px] font-semibold tracking-tight text-foreground">
            {option.title}
          </h3>
          <p class="mt-2 flex-1 text-[15px] leading-relaxed text-muted-foreground">
            {option.description}
          </p>
          <a
            href={option.href}
            rel="noreferrer"
            class="mt-5 inline-flex items-center gap-1.5 text-[14px] font-medium text-primary hover:underline"
          >
            {option.cta}
            <Icon name="arrow" size={14} />
          </a>
        </div>
      {/each}
    </div>

    <p class="mt-8 text-[15px] text-faint">{m.home_support_note()}</p>
  </div>
</section>

<section class="relative overflow-hidden border-t border-border-subtle">
  <div
    class="pointer-events-none absolute bottom-[-40%] left-1/2 h-[500px] w-[800px] -translate-x-1/2 rounded-full bg-primary/15 blur-[120px]"
  ></div>
  <div class="relative mx-auto max-w-[1200px] px-5 py-24 text-center sm:px-8 sm:py-28">
    <h2 class="mx-auto max-w-2xl text-4xl font-bold tracking-[-0.03em] text-foreground sm:text-5xl">
      <span class="text-sheen">{m.home_cta_title_oss()}</span>
      {m.home_cta_title_rest_oss()}
    </h2>
    <p class="mx-auto mt-5 max-w-xl text-lg text-muted-foreground">
      {m.home_cta_desc_oss()}
    </p>
    <div class="mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row">
      <Button href={GITHUB_RELEASES} size="lg" class="w-full sm:w-auto">
        <Icon name="arrow" size={17} />
        {m.nav_download_release()}
      </Button>
      <Button
        href={localizeHref('/roadmap')}
        variant="secondary"
        size="lg"
        class="w-full sm:w-auto"
      >
        {m.home_cta_roadmap()}
      </Button>
    </div>
  </div>
</section>
