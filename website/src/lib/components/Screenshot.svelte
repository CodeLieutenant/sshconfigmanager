<script lang="ts">
  import { asset } from '$app/paths';
  interface Props {
    name?: string;
    alt: string;
    class?: string;
    sizes?: string;
    priority?: boolean;
    width?: number;
    height?: number;
  }
  let {
    name = '01-host-detail',
    alt,
    class: className = '',
    sizes = '(min-width: 1024px) 640px, 92vw',
    priority = false,
    width = 1440,
    height = 900
  }: Props = $props();

  const base = $derived(asset(`/screenshots/${name}`));
</script>

<picture class="block {className}">
  <source type="image/avif" srcset="{base}-720.avif 720w, {base}-1440.avif 1440w" {sizes} />
  <source type="image/webp" srcset="{base}-720.webp 720w, {base}-1440.webp 1440w" {sizes} />
  <img
    src="{base}-1440.png"
    {alt}
    {width}
    {height}
    class="block h-auto w-full"
    loading={priority ? 'eager' : 'lazy'}
    fetchpriority={priority ? 'high' : 'auto'}
    decoding={priority ? 'auto' : 'async'}
  />
</picture>
