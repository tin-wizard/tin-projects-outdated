# TIN Projects white-label changes

TIN Projects is Huly (hcengineering/platform, EPL-2.0) with TIN branding. Branch `tin/main` =
upstream `develop` + the changes below. Keep this list complete: it is what you re-apply or
resolve when rebasing onto a newer upstream.

Product: **TIN Projects** · Tagline: **Plan. Collaborate. Deliver.** · Domain: `projects.tin.info`

## 1. Configuration only (no code; `tin/selfhost/`)

| What | Where |
|---|---|
| Browser title, login heading, favicons, manifest, English-only UI | `branding.json` (keyed by host; served to the browser via `BRANDING_URL`) |
| Email/notification product name | `branding.json` via `BRANDING_PATH` (account, transactor), `PRODUCT_NAME` (account) |
| New-workspace content without Huly sample docs | `init/script.yaml` via `INIT_REPO_DIR` |
| Sidebar logo | Per workspace: Settings → Workspace → icon (no code) |

Add a host to `branding.json` for every address the app is served from, or that host falls back to "Platform".

## 2. Code changes (kept minimal for easy rebases)

| File | Change |
|---|---|
| `dev/prod/src/index.ejs` | `<title>` and default favicon → TIN |
| `dev/prod/src/platform.ts` | Fallback sign-up URL `https://huly.io/signup` → local `/login/signup` |
| `dev/prod/public/tin/*` | **Placeholder** icons + `site.webmanifest` (new folder) |
| `plugins/login-resources/.../icons/LoginIcon.svelte` | Login logo → **placeholder** mark |
| `plugins/onboard-resources/.../icons/OnboardIcon.svelte` | Onboarding logo → **placeholder** mark |
| `plugins/{login,onboard,notification,setting,workbench,calendar}-assets/lang/en.json` | User-facing "Huly" → "TIN Projects" (9 strings) |
| `server/account/lang/en.json` | Invite, password-setup and all HTML email headers/footers → TIN Projects |

Only English strings are changed; `branding.json` limits the UI to English.

## 3. Deliberately unchanged

- **License and copyright notices** in source files (EPL-2.0 requires keeping them) and the upstream `LICENSE`.
- "Huly Unified Format" (export format name), Google API privacy statements (legal text, only shown if Google integrations are configured), Huly Mail and billing strings (features not deployed).
- Help menu: "Contact us" opens Huly's community Slack and "Open documentation" opens docs.huly.io (`plugins/support/src/index.ts`). **Decision needed:** point these at a TIN support channel/wiki, or keep them.
- Internal identifiers (`huly.*` storage keys, branding key `huly`, package names, CSS variables): not user-facing; renaming them would break upgrades.

## 4. Replacing the placeholder assets

Official assets needed (none supplied yet):

- `dev/prod/public/tin/favicon.svg` (square, works at 16 px)
- `dev/prod/public/tin/apple-touch-icon.png` 180×180, `icon-192.png` 192×192, `icon-512.png` 512×512
- Login/onboarding mark: replace the SVG in `LoginIcon.svelte` and `OnboardIcon.svelte` (rendered 16×16, on a dark background)
- Optional: workspace icon (upload in Settings)

Then rebuild the `front` image (`tin/selfhost/build-images.sh`).
