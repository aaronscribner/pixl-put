// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// SEO-first config: static output, canonical site URL set so OG/sitemap/canonical
// links resolve absolutely. Update `site` when the production domain is final.
export default defineConfig({
    site: 'https://pixput.app',
    output: 'static',
    trailingSlash: 'never',
    integrations: [
        sitemap({
            // Robots.txt is hand-written under public/ — sitemap link added there.
            changefreq: 'monthly',
            priority: 0.8,
        }),
    ],
    build: {
        // CF Pages serves /index.html for /, no surprises.
        format: 'directory',
        inlineStylesheets: 'auto',
    },
});
