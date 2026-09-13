import { describe, it, expect } from 'vitest';
import { render } from 'vitest-browser-svelte';
import { page } from 'vitest/browser';
import AppWindow from './AppWindow.svelte';

describe('AppWindow', () => {
  it('renders the screenshot through a <picture>, not a bare <img>', async () => {
    render(AppWindow, { alt: 'App window' });
    const img = page.getByRole('img', { name: 'App window' }).element() as HTMLImageElement;
    expect(img.closest('picture')).not.toBeNull();
    expect(img.getAttribute('src')).toBe('/screenshots/01-host-detail-1440.png');
  });

  it('defaults to the host-detail screenshot and is lazy', async () => {
    render(AppWindow, { alt: 'Default' });
    const picture = (
      page.getByRole('img', { name: 'Default' }).element() as HTMLImageElement
    ).closest('picture')!;
    const avif = picture.querySelector('source[type="image/avif"]')!.getAttribute('srcset');
    expect(avif).toContain('/screenshots/01-host-detail-1440.avif 1440w');
    const img = picture.querySelector('img')!;
    expect(img.getAttribute('loading')).toBe('lazy');
  });

  it('passes a custom name through to the underlying srcset', async () => {
    render(AppWindow, { name: '08-version-history', alt: 'History' });
    const picture = (
      page.getByRole('img', { name: 'History' }).element() as HTMLImageElement
    ).closest('picture')!;
    const avif = picture.querySelector('source[type="image/avif"]')!.getAttribute('srcset');
    expect(avif).toContain('/screenshots/08-version-history-720.avif 720w');
  });

  it('keeps the .app-frame class and appends a caller class', async () => {
    render(AppWindow, { alt: 'Framed', class: 'relative' });
    const picture = (
      page.getByRole('img', { name: 'Framed' }).element() as HTMLImageElement
    ).closest('picture')!;
    expect(picture.className).toContain('app-frame');
    expect(picture.className).toContain('relative');
  });
});
