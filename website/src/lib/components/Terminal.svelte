<script lang="ts">
  import type { Snippet } from 'svelte';

  let {
    title = '~/.ssh/config',
    class: className = '',
    children
  }: { title?: string; class?: string; children?: Snippet } = $props();
</script>

<div
  class={`ring-hairline overflow-hidden rounded-xl border border-border bg-card shadow-2xl ${className}`}
>
  <div class="flex h-10 items-center gap-3 border-b border-border-subtle bg-surface px-4">
    <div class="flex items-center gap-2">
      <span class="h-3 w-3 rounded-full bg-[#ff5f57]"></span>
      <span class="h-3 w-3 rounded-full bg-[#febc2e]"></span>
      <span class="h-3 w-3 rounded-full bg-[#28c840]"></span>
    </div>
    <span class="font-mono text-[12px] text-faint">{title}</span>
  </div>

  <div class="p-5">
    {#if children}
      {@render children()}
    {:else}
      <pre class="overflow-x-auto font-mono text-[13px] leading-[1.7]"><span class="text-faint"
          ># Work bastion — jump host</span
        >
<span class="text-primary">Host</span> <span class="text-silver">bastion</span>
  <span class="text-primary">HostName</span> <span class="text-muted-foreground"
          >bastion.acme.io</span
        >
  <span class="text-primary">User</span> <span class="text-muted-foreground">deploy</span>
  <span class="text-primary">IdentityFile</span> <span class="text-muted-foreground"
          >~/.ssh/id_ed25519</span
        >
  <span class="text-primary">ForwardAgent</span> <span class="text-muted-foreground">yes</span>

<span class="text-faint"># Reached through the bastion above</span>
<span class="text-primary">Host</span> <span class="text-silver">prod-db</span>
  <span class="text-primary">HostName</span> <span class="text-muted-foreground">10.0.4.12</span>
  <span class="text-primary">ProxyJump</span> <span class="text-muted-foreground">bastion</span>
  <span class="text-primary">LocalForward</span> <span class="text-muted-foreground"
          >5432 localhost:5432</span
        ></pre>
    {/if}
  </div>
</div>
