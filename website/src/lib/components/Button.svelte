<script lang="ts">
  import type { Snippet } from 'svelte';

  type Variant = 'primary' | 'secondary' | 'ghost' | 'outline';
  type Size = 'sm' | 'md' | 'lg';

  let {
    variant = 'primary',
    size = 'md',
    href = undefined,
    class: className = '',
    children,
    ...rest
  }: {
    variant?: Variant;
    size?: Size;
    href?: string;
    class?: string;
    children?: Snippet;
    [key: string]: unknown;
  } = $props();

  const base =
    'group/btn relative inline-flex items-center justify-center gap-2 rounded-[10px] font-semibold tracking-tight whitespace-nowrap transition-all duration-150 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/70 focus-visible:ring-offset-2 focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-50';

  const variants: Record<Variant, string> = {
    primary:
      'bg-primary text-primary-foreground shadow-[0_8px_24px_-8px_var(--accent-glow)] hover:bg-cyan-soft hover:shadow-[0_12px_30px_-8px_var(--accent-glow-strong)]',
    secondary:
      'bg-secondary text-foreground border border-border hover:border-border-strong hover:bg-elevated',
    outline: 'border border-border text-foreground hover:border-border-strong hover:bg-card',
    ghost: 'text-muted-foreground hover:text-foreground hover:bg-card'
  };

  const sizes: Record<Size, string> = {
    sm: 'h-9 px-4 text-[13px]',
    md: 'h-11 px-5 text-[15px]',
    lg: 'h-12 px-6 text-[15px]'
  };

  const cls = $derived(`${base} ${variants[variant]} ${sizes[size]} ${className}`);
</script>

<svelte:element this={href ? 'a' : 'button'} {href} class={cls} {...rest}>
  {@render children?.()}
</svelte:element>
