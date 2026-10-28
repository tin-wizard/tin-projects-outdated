# TIN Projects: self-hosting runbook

TIN Projects runs the official [huly-selfhost](https://github.com/hcengineering/huly-selfhost) Docker Compose
stack with our own images. Nothing here replaces upstream components; we only override them.

```
upstream/compose.yml   vendored unchanged from huly-selfhost (commit in upstream/SOURCE_COMMIT)
.huly.nginx            vendored unchanged (in-stack nginx routing)
compose.tin.yml        TIN overrides: our images, branding, health checks, Caddy (HTTPS), mail, fixes
branding.json          host-keyed branding (title, icons, English-only UI)
init/script.yaml       new-workspace setup without Huly sample content
env/common.env         shared settings     env/<staging|production>.env   per-environment settings
env/secrets.<env>.env  generated per server, never committed (git-ignored)
tin.sh                 the only command you need (wraps docker compose)
build-images.sh        builds + tags our images (used locally and by CI)
```

Branding details and the placeholder assets to replace: [../BRANDING.md](../BRANDING.md).

## Fixes over upstream compose (in compose.tin.yml)

- **PostgreSQL 18 replaces CockroachDB** (see "Database" below). CockroachDB is behind profile `cockroach` (unused).
- `kvs` is disabled (profile `kvs`): only the Gmail/mail-worker integrations use it, it logs the full DB URL
  including the password, and it has no TLS so it cannot reach managed Postgres. Its port 8094 is unpublished.
- nginx is restarted by `tin.sh` after every `up` (it caches container IPs; recreated services otherwise give 502).
- nginx binds to `127.0.0.1` only; public traffic goes through Caddy (HTTPS).
- Transactor `FRONT_URL` was hard-coded to `http://localhost:8087` (broke links in emails).
- Redpanda health check passed SASL credentials to a broker without SASL, so it was always unhealthy.
- Known, accepted: MinIO keeps upstream's default credentials; it is reachable only on the internal Docker network.

## Images

All app images are built from `tin/main` (upstream `develop` + TIN branding) and named
`ghcr.io/tin-wizard/tin-projects-<service>:<TIN_VERSION>`. Only `kvs` (a separate upstream Rust repo,
no branding) and the third-party images (PostgreSQL, Redpanda, MinIO, Elasticsearch, nginx, Caddy) are upstream.

- **CI (for servers):** GitHub → Actions → "TIN images" → Run workflow with a version, e.g. `dev-f292d16-tin.2`.
  Builds `linux/amd64` and pushes to GHCR. Manual-only on purpose: upstream's `main.yml` triggers on `v*` tags.
- **Local:** `TIN_VERSION=dev-f292d16-tin.2 tin/selfhost/build-images.sh` (Node 22; ~30–60 min cold, host architecture).

Set the same `TIN_VERSION` in `env/staging.env` / `env/production.env`.

## Server (Hetzner)

Upstream requires at least 2 vCPU / 8 GB RAM and recommends 4 vCPU / 16 GB. Measured locally (idle test
workspaces): ~3.4 GiB RAM, mostly Elasticsearch 1.3 GiB and Redpanda 1.0 GiB; PostgreSQL idles at ~30 MiB.
Usage grows with data and active users.

- Staging: 8 GB RAM class server. Production: 16 GB RAM class, x86 (our CI builds amd64).
- Location: any EU location; pick the one closest to the team.
- Enable Hetzner server **Backups** (daily disk snapshots) in addition to `tin.sh backup`.
- Firewall: allow 22 (your IPs only), 80, 443. Nothing else is published by the stack.

## Deploy

```bash
# on the server (Ubuntu 24.04, Docker Engine + compose plugin installed)
git clone https://github.com/tin-wizard/tin-projects.git && cd tin-projects && git checkout tin/main
cd tin/selfhost
./tin.sh production init-secrets          # once; back up env/secrets.production.env somewhere safe
$EDITOR env/production.env                 # ACME_EMAIL, MAIL_SOURCE, SMTP_HOST; SMTP creds in the secrets file
echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin   # if the packages are private
./tin.sh production pull
./tin.sh production up -d --wait
./tin.sh production ps
```

HTTPS: Caddy (profile `https`, enabled in `production.env`) gets a Let's Encrypt certificate for `HOST_ADDRESS`
automatically once the DNS A/AAAA record points to the server and ports 80/443 are open.

Staging uses the same files with `staging` instead of `production`. Locally it runs on http://localhost:8087
(loopback only, no HTTPS, no email).

## Database: PostgreSQL 18 on the same server (decision 2026-10-28)

Why not upstream's CockroachDB: huly-selfhost pins v24.2, which reached end of support on 2025-02-12, and every
CockroachDB release since 24.3 (incl. later 24.2 patches) is under a proprietary licence: production needs an annually
renewed key (free only under $10M revenue) with mandatory telemetry, else throttling.
Why PostgreSQL: upstream CI runs its full UI test suite on `postgres:18` (`tests/docker-compose.purepg.yaml`), it is
open source, supported until ~Nov 2030, and local to the app. Why not Neon/Supabase: every query crosses providers.

Measured with `node bench.mjs` (same images, same Mac; Neon `aws-eu-central-1`, 1 CU, direct endpoint):

| | PostgreSQL 18 (local) | CockroachDB (local) | Neon |
|---|---|---|---|
| Raw DB round trip (pgbench `SELECT 1`) | 0.11 ms | 3.6 ms | 17.5 ms (this Mac → Frankfurt) |
| Sign-up | 83–151 ms | ~300 ms | ~1.1 s |
| Create workspace (until usable) | 5.3–7.1 s | 6.9–7.7 s | 44–47 s |
| Read (median / p90) | 3–5 / 4–7 ms | 6–15 / 15–35 ms | 22 / 26–41 ms |
| Write (median / p90) | 7–11 / 11–35 ms | 23–31 / 76–93 ms | 95–97 / 115–260 ms |

The app used 7 of PostgreSQL's 100 default connections. Neon worked but needs the direct endpoint, no
`channel_binding`, and `kvs` disabled (no TLS). Growth path: move PostgreSQL to a dedicated Hetzner server on the
private network; nothing else changes (`CR_DB_URL`).

## Health

```bash
./tin.sh production ps                         # all services Up; account/front/redpanda/minio/elastic "healthy"
./tin.sh production logs --since 10m | grep -i error
```

Troubleshooting:
- Elasticsearch stuck "unhealthy" at high CPU after a fresh start (seen once on a new volume):
  `./tin.sh <env> restart elastic` (healthy within ~2 min).
- 502 Bad Gateway after updating images: `./tin.sh <env> restart nginx` (tin.sh `up` does this automatically).
- "Preparing workspace for new version…" forever: the images report an older model version than the data
  (e.g. data created by a `v0.7.4xx` release opened with `develop` images). Do not mix release and develop data.

## Backup

```bash
./tin.sh production backup    # -> backups/production-<UTC time>/{pg-base.tar.gz, files.tgz, secrets.production.env}
```

Online: `pg_basebackup` (consistent) plus a live copy of uploaded files. Copy the folder off the server (it contains
secrets). Suggested cron (daily 03:00), then sync `backups/` to off-site storage:

```
0 3 * * * cd /opt/tin-projects/tin/selfhost && ./tin.sh production backup >> backups/backup.log 2>&1
```

Point-in-time recovery: PostgreSQL archives every WAL segment (at least every 5 min) into the `pg_data` volume.
Each backup prunes WAL older than the previous base backup, so you can restore to any moment since the previous
backup (≥ 24 h with daily backups). The WAL archive is on the server only: after losing the server you restore to
the last off-site backup. For continuous off-site PITR, ship WAL to object storage with WAL-G or pgBackRest.

Elasticsearch (search index) and Redpanda (queue) are not backed up. After a restore, search may miss recent
documents until they are re-indexed (not verified).

## Recovery

```bash
# Same or new server, repo checked out, images available:
cp <backup>/secrets.production.env env/                  # same SECRET and DB password as the backup
./tin.sh production restore <backup-dir> --yes            # base backup + replay WAL archive to the latest state
./tin.sh production restore <backup-dir> --yes --time '2026-10-28 14:30:00+00'   # or: to a point in time
./tin.sh production ps
```

Restore archives the current WAL first, so "latest" includes changes up to the moment you run it. Pick the newest
backup taken *before* the target time. Uploaded files are added back without deleting newer ones.
Tested 2026-10-28 on staging: restore-to-latest kept data created after the backup; `--time` removed it.

Then log in and check a workspace. Whole-server loss: create a server from the latest Hetzner backup, or a fresh
server + the steps above.

## Upgrading

1. Read huly-selfhost `MIGRATION.md` for the target version; re-sync `upstream/` files if they changed.
2. Rebase `tin/main` onto the new upstream ref; resolve conflicts in the files listed in `../BRANDING.md`.
3. Build new images with a new `TIN_VERSION`, deploy to staging, test, then production.
4. Always `./tin.sh production backup` before `up -d` with new images (schema migrations run on start).
5. PostgreSQL minor updates (18.x) come with `pull`. A major upgrade (19+) needs `pg_upgrade` or dump/restore;
   plan it before 18 reaches end of life (~Nov 2030).
