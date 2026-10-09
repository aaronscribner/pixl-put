# PixPut Marketing Site

Astro static site, deployed to Cloudflare Pages. SEO-first: server-rendered HTML, meta tags, OG, Twitter cards, `schema.org/SoftwareApplication` JSON-LD, sitemap, robots.txt.

## Layout

- `src/layouts/BaseLayout.astro` — shared shell + meta tags + global styles. All pages should compose this.
- `src/pages/index.astro` — landing page (hero, features, how-it-works, FAQ).
- `src/pages/privacy.astro` — privacy policy.
- `src/pages/changelog.astro` — release notes.
- `public/robots.txt`, `public/favicon.svg`, `public/og.png` (add when ready).

## Local dev

```bash
cd marketing
npm install
npm run dev          # http://localhost:4321
```

## Deploy (Cloudflare Pages)

```bash
npm run build
npm run deploy       # uses wrangler pages deploy
```

Or wire CF Pages to the GitHub repo for auto-deploy on push.

## TODOs before first deploy

- Add `public/og.png` (1200×630), `public/favicon.svg`, `public/apple-touch-icon.png`.
- Confirm `site` in `astro.config.mjs` matches the final production domain (`pixput.app`).
- Set the CF Pages custom domain to point at `pixput.app`.
