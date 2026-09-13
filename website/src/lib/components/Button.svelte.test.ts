import { describe, it, expect } from 'vitest';
import { render } from 'vitest-browser-svelte';
import { page } from 'vitest/browser';
import { createRawSnippet } from 'svelte';
import Button from './Button.svelte';

function label(text: string) {
  return createRawSnippet(() => ({ render: () => `<span>${text}</span>` }));
}

describe('Button', () => {
  it('renders a <button> element by default', async () => {
    render(Button, { children: label('Save') });
    const btn = page.getByRole('button', { name: 'Save' });
    await expect.element(btn).toBeInTheDocument();
    expect(btn.element().tagName).toBe('BUTTON');
  });

  it('renders an anchor when href is provided', async () => {
    render(Button, { href: '/pricing', children: label('Pricing') });
    const link = page.getByRole('link', { name: 'Pricing' });
    await expect.element(link).toBeInTheDocument();
    expect(link.element().tagName).toBe('A');
    await expect.element(link).toHaveAttribute('href', '/pricing');
  });

  it('forwards rest props to the rendered element', async () => {
    render(Button, { type: 'submit', disabled: true, children: label('Go') });
    const btn = page.getByRole('button', { name: 'Go' });
    await expect.element(btn).toHaveAttribute('type', 'submit');
    await expect.element(btn).toBeDisabled();
  });

  it('applies variant and size utility classes', async () => {
    render(Button, { variant: 'ghost', size: 'lg', children: label('Ghost') });
    const btn = page.getByRole('button', { name: 'Ghost' });
    const cls = btn.element().className;
    expect(cls).toContain('h-12');
    expect(cls).toContain('text-muted-foreground');
  });

  it('appends a caller-supplied class', async () => {
    render(Button, { class: 'w-full', children: label('Wide') });
    const btn = page.getByRole('button', { name: 'Wide' });
    expect(btn.element().className).toContain('w-full');
  });
});
