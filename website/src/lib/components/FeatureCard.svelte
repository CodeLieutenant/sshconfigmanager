<script lang="ts">
  import Icon from './Icon.svelte';

  let {
    icon,
    title,
    description,
    class: className = ''
  }: { icon: string; title: string; description: string; class?: string } = $props();
</script>

<div
  class={`group relative cursor-pointer overflow-hidden rounded-2xl border border-border-subtle bg-card p-6 transition-all duration-200
    hover:border-border hover:bg-muted hover:shadow-[0_0_28px_-6px_var(--accent-glow)] ${className}`}
>
  <div
    class="absolute -top-20 -right-10 h-44 w-44 rounded-full bg-primary/8 opacity-0 blur-3xl transition-opacity duration-300 group-hover:opacity-100"
  ></div>

  <div
    class="grid h-11 w-11 place-items-center rounded-xl bg-primary/10 text-primary ring-1 ring-primary/15 transition-all duration-200 group-hover:bg-primary/20 group-hover:ring-primary/25"
  >
    <Icon name={icon} size={20} />
  </div>

  <h3 class="mt-5 text-[18px] font-semibold tracking-tight text-foreground">{title}</h3>
  <p class="mt-2 text-[15px] leading-relaxed text-muted-foreground">{description}</p>
</div>
