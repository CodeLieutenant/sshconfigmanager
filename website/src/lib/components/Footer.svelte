<script lang="ts">
  import Logo from './Logo.svelte';
  import { localizeHref } from '$lib/paraglide/runtime';
  import { APP_STORE_URL } from '$lib/appstore';
  import {
    GITHUB_REPO,
    GITHUB_RELEASES,
    GITHUB_ISSUES,
    GITHUB_DISCUSSIONS,
    GITHUB_SPONSORS,
    LICENSE_URL
  } from '$lib/links';
  import * as m from '$lib/paraglide/messages';

  const columns = $derived([
    {
      title: m.footer_col_project(),
      links: [
        { label: m.footer_source_code(), href: GITHUB_REPO },
        { label: m.footer_releases(), href: GITHUB_RELEASES },
        { label: m.footer_roadmap(), href: '/roadmap' },
        { label: m.footer_license(), href: LICENSE_URL }
      ]
    },
    {
      title: m.footer_col_community(),
      links: [
        { label: m.footer_issues(), href: GITHUB_ISSUES },
        { label: m.footer_discussions(), href: GITHUB_DISCUSSIONS },
        { label: m.footer_sponsor(), href: GITHUB_SPONSORS },
        { label: m.footer_mac_app_store(), href: APP_STORE_URL }
      ]
    },
    {
      title: m.footer_col_legal(),
      links: [
        { label: m.footer_privacy(), href: '/privacy' },
        { label: m.footer_terms(), href: '/terms' }
      ]
    }
  ]);

  const isExternal = (href: string) => href.startsWith('http');
</script>

<footer class="border-t border-border-subtle bg-surface">
  <div class="mx-auto max-w-[1200px] px-5 py-16 sm:px-8">
    <div class="flex flex-col gap-12 lg:flex-row lg:justify-between">
      <div class="max-w-xs">
        <Logo />
        <p class="mt-5 text-[15px] leading-relaxed text-faint">
          {m.footer_tagline_oss()}
        </p>
        <p class="mt-4 font-mono text-[13px] text-muted-foreground">
          {m.footer_platforms()}
        </p>
      </div>

      <div class="grid grid-cols-2 gap-10 sm:grid-cols-3 lg:gap-16">
        {#each columns as col (col.title)}
          <div>
            <h4 class="text-[12px] font-semibold tracking-[0.08em] text-faint uppercase">
              {col.title}
            </h4>
            <ul class="mt-4 space-y-3">
              {#each col.links as link (link.label)}
                <li>
                  <a
                    href={isExternal(link.href) ? link.href : localizeHref(link.href)}
                    rel={isExternal(link.href) ? 'noreferrer' : undefined}
                    class="text-[14px] text-muted-foreground transition-colors hover:text-foreground"
                    >{link.label}</a
                  >
                </li>
              {/each}
            </ul>
          </div>
        {/each}
      </div>
    </div>

    <div class="mt-14 h-px w-full bg-border-subtle"></div>

    <div class="mt-6 flex flex-col items-start justify-between gap-4 sm:flex-row sm:items-center">
      <p class="text-[14px] text-faint">{m.footer_copyright_oss()}</p>
      <a
        href={GITHUB_REPO}
        rel="noreferrer"
        class="text-faint transition-colors hover:text-foreground"
        aria-label="GitHub"
      >
        <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
          <path
            d="M12 .5C5.73.5.5 5.73.5 12a11.5 11.5 0 0 0 7.86 10.92c.575.106.785-.25.785-.555 0-.274-.01-1.002-.015-1.967-3.196.695-3.87-1.54-3.87-1.54-.523-1.328-1.277-1.682-1.277-1.682-1.043-.713.08-.699.08-.699 1.153.082 1.76 1.184 1.76 1.184 1.026 1.757 2.693 1.25 3.35.955.103-.743.4-1.25.728-1.538-2.552-.29-5.236-1.276-5.236-5.68 0-1.255.448-2.28 1.183-3.084-.119-.29-.513-1.46.112-3.043 0 0 .965-.309 3.162 1.178a11 11 0 0 1 5.756 0c2.196-1.487 3.16-1.178 3.16-1.178.626 1.583.232 2.753.114 3.043.737.804 1.18 1.83 1.18 3.084 0 4.415-2.688 5.386-5.248 5.67.412.355.78 1.056.78 2.128 0 1.537-.014 2.776-.014 3.153 0 .308.207.667.79.554A11.5 11.5 0 0 0 23.5 12C23.5 5.73 18.27.5 12 .5z"
          />
        </svg>
      </a>
    </div>
  </div>
</footer>
