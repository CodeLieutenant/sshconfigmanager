# website — www.sshmanager.app

A static SvelteKit 2 and Svelte 5 site. It builds to plain files. The
`.github/workflows/website.yml` workflow deploys the files to GitHub Pages when a
change to `website/` reaches `main`.

## Rules

- **No server code.** `adapter-static` runs with `strict: true`. Every route
  prerenders. A `+page.server.ts` file, a form action or a `$lib/server` import
  stops the build.
- **No accounts, payments, analytics, cookies, forms or telemetry.** The site
  links to GitHub Releases for downloads, to GitHub Issues for feedback and to
  the Mac App Store.
- **One license.** The software uses the Apache License 2.0. `LICENSE_URL` in
  `src/lib/links.ts` points to `LICENSE.md`.
- **One price constant.** `APP_STORE_PRICE` in `src/lib/links.ts` holds the Mac
  App Store price. That build is the same app. Every feature is free in every
  build.
- **One contact.** `CONTACT_EMAIL` in `src/lib/links.ts` is the only email
  address on the site.
- **Download links live in `src/lib/links.ts`.** The Linux `.deb`, `.rpm` and
  Flatpak links point to the latest GitHub release.
- **Routes are listed** in `src/lib/routes.ts`. Add a new route there, so that
  the sitemap includes it.
- **Policy date.** `POLICY_UPDATED` in `src/lib/policy.ts` is the "Last updated"
  date on the privacy and terms pages. Change it when the text of those pages
  changes.
- **Images show no private data.** A screenshot must not show an email address,
  a real host name or a paid-tier badge.

## Pages

| Route                         | Content                                                                                          |
| ----------------------------- | ------------------------------------------------------------------------------------------------ |
| `/`                           | Hero, features, config editor, tunnels, security, downloads for macOS and Linux, support options |
| `/roadmap`                    | Now, next, later and shipped columns                                                             |
| `/privacy`                    | The app, Gist sync and the website collect no data. GitHub Pages keeps access logs               |
| `/terms`                      | Apache License 2.0, no warranty, Apple standard EULA for the App Store build                     |
| `/robots.txt`, `/sitemap.xml` | Generated from `PUBLIC_ROUTES`                                                                   |

Each page is available in `en`, `de`, `nl` and `el` under a Paraglide URL
prefix. English has no prefix. All text lives in `messages/<locale>.json`. Each
locale file must have the same keys as `messages/en.json`.

## Commands

```sh
pnpm install --frozen-lockfile
pnpm dev
pnpm lint
pnpm check
pnpm test:unit
pnpm test:browser
pnpm test
pnpm build
```

`pnpm test:browser` and `pnpm test` need Chromium. Install it with
`pnpm exec playwright install chromium`. CI runs the browser tests only on a
manual `workflow_dispatch` run.

## Custom domain

`static/CNAME` sets the domain. `SITE.url` in `src/lib/seo.ts` must match it,
because the canonical, hreflang and sitemap URLs use it.
