# Flan MCP Marketing Site (Zola + Cloudflare Workers Static Assets)

This directory contains a Zola-based marketing site deployed to **Cloudflare Workers static assets** (not Cloudflare Pages).

## Prerequisites

- [Zola](https://www.getzola.org/documentation/getting-started/installation/)
- Node.js 18+
- Cloudflare account
- Wrangler CLI (`npm install` in this directory)

## Local development

```bash
cd marketing
npm install
npm run dev
```

Open `http://127.0.0.1:1111`.

## Build

```bash
cd marketing
npm run build
```

This outputs static files to `marketing/public`.

## Deploy to Cloudflare Workers (Static Assets)

1. Authenticate Wrangler:

```bash
npx wrangler login
```

2. Build and deploy:

```bash
cd marketing
npm run deploy
```

Wrangler reads `wrangler.toml` and uploads `./public` via the Workers `assets` config.

## Important

- This setup intentionally uses Workers static assets (`[assets]` in `wrangler.toml`).
- It does **not** use `pages_build_output_dir` and does **not** target Cloudflare Pages.
