<script lang="ts">
  let { size = 30, class: className = '' }: { size?: number; class?: string } = $props();

  const icon = $derived(Math.round(size * 0.56));
</script>

<span
  class={`relative inline-grid shrink-0 place-items-center ${className}`}
  style:width="{size}px"
  style:height="{size}px"
>
  <span
    class="pointer-events-none absolute inset-[-5px] rounded-[11px] bg-primary/35 opacity-55 blur-[11px] transition-[opacity,transform] duration-300 group-hover/logo:scale-105 group-hover/logo:opacity-90"
    aria-hidden="true"
  ></span>

  <span
    class="relative grid h-full w-full place-items-center overflow-hidden rounded-[8px] border border-primary/30 bg-gradient-to-b from-[#1c1c22] via-[#141417] to-[#0e0e11] shadow-[0_0_22px_-5px_var(--accent-glow),inset_0_1px_0_rgba(255,255,255,0.08)] ring-1 ring-white/[0.04] transition-[box-shadow,border-color,transform] duration-300 ring-inset group-hover/logo:border-primary/45 group-hover/logo:shadow-[0_0_32px_-3px_var(--accent-glow-strong),inset_0_1px_0_rgba(255,255,255,0.1)]"
  >
    <span
      class="pointer-events-none absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-primary/40 to-transparent"
      aria-hidden="true"
    ></span>

    <svg
      width={icon}
      height={icon}
      viewBox="0 0 16 16"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden="true"
      class="relative text-primary drop-shadow-[0_0_6px_var(--accent-glow)]"
    >
      <rect
        x="2.25"
        y="3.25"
        width="11.5"
        height="9.5"
        rx="1.75"
        stroke="currentColor"
        stroke-width="1.1"
        class="text-primary/40"
      />

      <circle cx="4.35" cy="5.35" r="0.5" fill="currentColor" class="text-primary/30" />
      <circle cx="5.85" cy="5.35" r="0.5" fill="currentColor" class="text-primary/22" />
      <circle cx="7.35" cy="5.35" r="0.5" fill="currentColor" class="text-primary/16" />

      <path
        d="M4.4 9.1 6.35 8 4.4 6.9"
        stroke="currentColor"
        stroke-width="1.15"
        stroke-linecap="round"
        stroke-linejoin="round"
      />

      <rect x="7.35" y="7.15" width="1.05" height="1.65" rx="0.15" fill="currentColor" />
    </svg>
  </span>
</span>
