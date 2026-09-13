import { describe, it, expect } from 'vitest';
import { render } from 'vitest-browser-svelte';
import { page } from 'vitest/browser';
import Screenshot from './Screenshot.svelte';

function pictureFor(alt: string): HTMLPictureElement {
  const img = page.getByRole('img', { name: alt }).element() as HTMLImageElement;
  const picture = img.closest('picture');
  if (!picture) throw new Error('img is not wrapped in a <picture>');
  return picture;
}

describe('Screenshot', () => {
  it('emits AVIF then WebP <source>s ahead of the <img> fallback, in that order', async () => {
    render(Screenshot, { name: '01-host-detail', alt: 'Host detail' });
    await expect.element(page.getByRole('img', { name: 'Host detail' })).toBeInTheDocument();

    const picture = pictureFor('Host detail');
    const types = [...picture.querySelectorAll('source')].map((s) => s.getAttribute('type'));
    expect(types).toEqual(['image/avif', 'image/webp']);
  });

  it('builds a 720w + 1440w srcset per format from the name', async () => {
    render(Screenshot, { name: '04-tunnels', alt: 'Tunnels' });
    const picture = pictureFor('Tunnels');
    const avif = picture.querySelector('source[type="image/avif"]')!.getAttribute('srcset');
    const webp = picture.querySelector('source[type="image/webp"]')!.getAttribute('srcset');
    expect(avif).toBe(
      '/screenshots/04-tunnels-720.avif 720w, /screenshots/04-tunnels-1440.avif 1440w'
    );
    expect(webp).toBe(
      '/screenshots/04-tunnels-720.webp 720w, /screenshots/04-tunnels-1440.webp 1440w'
    );
  });

  it('falls back to the downscaled 1440 PNG with intrinsic dimensions (no CLS)', async () => {
    render(Screenshot, { name: '05-keys', alt: 'Keys' });
    const img = page.getByRole('img', { name: 'Keys' }).element() as HTMLImageElement;
    expect(img.getAttribute('src')).toBe('/screenshots/05-keys-1440.png');
    expect(img.getAttribute('width')).toBe('1440');
    expect(img.getAttribute('height')).toBe('900');
  });

  it('is lazy and low-priority by default', async () => {
    render(Screenshot, { name: '06-agent', alt: 'Agent' });
    const img = page.getByRole('img', { name: 'Agent' }).element() as HTMLImageElement;
    expect(img.getAttribute('loading')).toBe('lazy');
    expect(img.getAttribute('fetchpriority')).toBe('auto');
    expect(img.getAttribute('decoding')).toBe('async');
  });

  it('loads eagerly at high priority when priority is set (the LCP hero)', async () => {
    render(Screenshot, { name: '01-host-detail', alt: 'Hero', priority: true });
    const img = page.getByRole('img', { name: 'Hero' }).element() as HTMLImageElement;
    expect(img.getAttribute('loading')).toBe('eager');
    expect(img.getAttribute('fetchpriority')).toBe('high');
  });

  it('reflects a custom sizes attribute onto both <source>s', async () => {
    render(Screenshot, { name: '01-host-detail', alt: 'Sized', sizes: '50vw' });
    const picture = pictureFor('Sized');
    for (const source of picture.querySelectorAll('source')) {
      expect(source.getAttribute('sizes')).toBe('50vw');
    }
  });

  it('applies a caller-supplied class to the <picture>', async () => {
    render(Screenshot, { name: '01-host-detail', alt: 'Framed', class: 'app-frame w-full' });
    const picture = pictureFor('Framed');
    expect(picture.className).toContain('app-frame');
    expect(picture.className).toContain('w-full');
  });
});
