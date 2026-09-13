import { paraglideVitePlugin } from '@inlang/paraglide-js';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vitest/config';
import { playwright } from '@vitest/browser-playwright';
import { sveltekit } from '@sveltejs/kit/vite';

const basePath = process.env.BASE_PATH ?? '';
const baseSegment = basePath ? `{${basePath.slice(1)}/}?` : '';
const localizedLocales = ['nl', 'de', 'el'] as const;
const urlPatterns = basePath
  ? [
      {
        pattern: `/${baseSegment}:path(.*)?`,
        localized: [
          ...localizedLocales.map(
            (locale) => [locale, `/${baseSegment}${locale}/:path(.*)?`] as [string, string]
          ),
          ['en', `/${baseSegment}:path(.*)?`] as [string, string]
        ]
      }
    ]
  : undefined;

export default defineConfig({
  plugins: [
    tailwindcss(),
    sveltekit(),
    paraglideVitePlugin({
      project: './project.inlang',
      outdir: './src/lib/paraglide',
      strategy: ['url', 'baseLocale'],
      urlPatterns
    })
  ],
  test: {
    expect: { requireAssertions: true },
    projects: [
      {
        extends: './vite.config.ts',
        test: {
          name: 'client',
          browser: {
            enabled: true,
            provider: playwright(),
            instances: [{ browser: 'chromium', headless: true }]
          },
          include: ['src/**/*.svelte.{test,spec}.{js,ts}']
        }
      },
      {
        extends: './vite.config.ts',
        test: {
          name: 'server',
          environment: 'node',
          include: ['src/**/*.{test,spec}.{js,ts}'],
          exclude: ['src/**/*.svelte.{test,spec}.{js,ts}']
        }
      }
    ]
  }
});
