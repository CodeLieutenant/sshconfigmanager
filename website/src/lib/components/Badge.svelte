<script lang="ts">
  import type { Snippet } from 'svelte';

  type Props = {
    dot?: boolean;
    class?: string;
    children?: Snippet;
  };

  let { dot = true, class: className = '', children }: Props = $props();
</script>

<span
  class={`inline-flex items-center gap-2 rounded-full border border-border bg-card/70 px-3 py-1.5 text-[13px] font-medium text-muted-foreground backdrop-blur ${className}`}
>
  {#if dot}
    <span class="relative flex h-1.5 w-1.5">
      <span
        class="absolute inline-flex h-full w-full animate-ping rounded-full bg-primary opacity-70"
      ></span>
      <span class="relative inline-flex h-1.5 w-1.5 rounded-full bg-primary"></span>
    </span>
  {/if}
  {@render children?.()}
</span>
