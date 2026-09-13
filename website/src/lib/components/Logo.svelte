<script lang="ts">
  import { localizeHref } from '$lib/paraglide/runtime';
  import LogoMark from './LogoMark.svelte';

  let { class: className = '' }: { class?: string } = $props();
</script>

<a
  href={localizeHref('/')}
  class={`group/logo inline-flex items-center gap-2.5 transition-transform duration-300 hover:-translate-y-px ${className}`}
  aria-label="SSH Config Manager — home"
>
  <LogoMark />
  <span class="text-[17px] font-semibold tracking-[-0.02em] text-foreground"
    >SSH Config Manager</span
  >
</a>
