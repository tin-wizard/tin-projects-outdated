#!/usr/bin/env bash
# TIN Projects deployment wrapper.
#   ./tin.sh <staging|production> init-secrets      generate env/secrets.<env>.env (once per server)
#   ./tin.sh <staging|production> backup            database + files + secrets into backups/
#   ./tin.sh <staging|production> restore <dir> --yes
#   ./tin.sh <staging|production> <compose args>    e.g. up -d, ps, logs -f front, down
set -euo pipefail
cd "$(dirname "$0")"

ENV_NAME="${1:-}"; shift || true
case "$ENV_NAME" in staging|production) ;; *) echo "usage: $0 <staging|production> <command>" >&2; exit 1 ;; esac
SECRETS="env/secrets.$ENV_NAME.env"

if [ "${1:-}" = "init-secrets" ]; then
  [ -f "$SECRETS" ] && { echo "$SECRETS already exists; refusing to overwrite (it would orphan existing data)." >&2; exit 1; }
  CR_PW=$(openssl rand -hex 24)
  umask 077
  cat > "$SECRETS" <<EOF
SECRET=$(openssl rand -hex 32)
CR_USER_PASSWORD=$CR_PW
CR_DB_URL=postgres://selfhost:$CR_PW@postgres:5432/huly
REDPANDA_ADMIN_PWD=$(openssl rand -hex 24)
SMTP_USERNAME=
SMTP_PASSWORD=
EOF
  echo "Wrote $SECRETS - back it up with the data; losing SECRET invalidates all sessions and tokens."
  exit 0
fi

[ -f "$SECRETS" ] || { echo "Missing $SECRETS; run: $0 $ENV_NAME init-secrets" >&2; exit 1; }

compose() {
  docker compose \
    --project-directory . \
    --env-file env/common.env --env-file "env/$ENV_NAME.env" --env-file "$SECRETS" \
    -f upstream/compose.yml -f compose.tin.yml \
    "$@"
}
PGDATA_DIR=/var/lib/postgresql/18/docker
WAL_ARCHIVE=/var/lib/postgresql/wal-archive
pg() { compose exec -T postgres "$@"; }
# Run a throwaway container sharing a service's volumes (works while that service is stopped).
with_volumes() { local svc=$1 image=$2; shift 2; docker run --rm --volumes-from "$(compose ps -aq "$svc")" "$@" "$image" sh -c "$CMD"; }

case "${1:-}" in
  # ./tin.sh <env> backup   -> backups/<env>-<utc>/{pg-base.tar.gz,files.tgz,secrets.<env>.env}
  # Online: pg_basebackup is consistent; files are copied live (blobs are written once).
  backup)
    ts=$(date -u +%Y%m%dT%H%M%SZ); out="backups/$ENV_NAME-$ts"
    (umask 077; mkdir -p "$out")
    pg pg_basebackup -U selfhost -D - -Ft -X fetch -z --checkpoint=fast > "$out/pg-base.tar.gz"
    CMD="tar czf /out/files.tgz -C /data ." with_volumes minio alpine:3.20 -v "$PWD/$out:/out"
    cp "$SECRETS" "$out/"
    # Keep WAL from the previous base backup on, so point-in-time restore reaches back at least one backup interval.
    # shortcut: the WAL archive stays on this server, so off-site restores are to backup time only; for continuous
    # off-site PITR, ship WAL to object storage with WAL-G or pgBackRest once a bucket exists.
    pg sh -c "ls $WAL_ARCHIVE/*.backup 2>/dev/null | sort | tail -2 | head -1 | xargs -r -n1 basename | xargs -r pg_archivecleanup $WAL_ARCHIVE"
    du -sh "$out"; echo "Backup written to $out - copy it off this server."
    ;;

  # ./tin.sh <env> restore <backup-dir> --yes [--time '2026-10-28 14:30:00+00']
  # REPLACES the database: restores the base backup, then replays this server's WAL archive to the latest state,
  # or to --time. Files from the backup are added back without deleting newer ones.
  # Requires the same secrets file as the backup (a copy is inside the backup dir).
  restore)
    dir="${2:?usage: $0 $ENV_NAME restore <backup-dir> --yes [--time '<timestamp>']}"
    [ "${3:-}" = "--yes" ] || { echo "This deletes the current $ENV_NAME database. Re-run with --yes." >&2; exit 1; }
    target=""; [ "${4:-}" = "--time" ] && target="${5:?--time needs a timestamp, e.g. '2026-10-28 14:30:00+00'}"
    [ -f "$dir/pg-base.tar.gz" ] && [ -f "$dir/files.tgz" ] || { echo "$dir is not a backup made by '$0 backup'" >&2; exit 1; }
    cmp -s "$dir/$(basename "$SECRETS")" "$SECRETS" || echo "WARNING: $SECRETS differs from the backup's copy; sessions/tokens may not survive." >&2
    in="$(cd "$dir" && pwd)"
    compose up -d --wait postgres minio
    # Archive the current, partly filled WAL segment too, or the last minutes before the restore are lost.
    seg=$(pg psql -U selfhost -d huly -Atc "SELECT pg_walfile_name(pg_switch_wal())")
    for _ in $(seq 60); do
      [ "$(pg psql -U selfhost -d huly -Atc "SELECT last_archived_wal >= '$seg' FROM pg_stat_archiver")" = t ] && break; sleep 1
    done
    compose stop
    # Wipe only PGDATA; the WAL archive next to it is what replays changes made after the backup.
    CMD="set -e; rm -rf $PGDATA_DIR; mkdir -p $PGDATA_DIR $WAL_ARCHIVE; tar xzf /in/pg-base.tar.gz -C $PGDATA_DIR
      echo \"restore_command = 'cp $WAL_ARCHIVE/%f %p'\" >> $PGDATA_DIR/postgresql.auto.conf
      echo \"recovery_target_action = 'promote'\" >> $PGDATA_DIR/postgresql.auto.conf
      [ -z \"\$TARGET\" ] || echo \"recovery_target_time = '\$TARGET'\" >> $PGDATA_DIR/postgresql.auto.conf
      touch $PGDATA_DIR/recovery.signal; chown -R postgres:postgres /var/lib/postgresql; chmod 700 $PGDATA_DIR" \
      with_volumes postgres postgres:18 -v "$in:/in:ro" -e TARGET="$target"
    CMD="tar xzf /in/files.tgz -C /data" with_volumes minio alpine:3.20 -v "$in:/in:ro"
    compose up -d --wait postgres
    # Drop the one-off recovery target so a later crash recovery is not stopped at it.
    pg psql -U selfhost -d huly -qc "ALTER SYSTEM RESET recovery_target_time" -c "SELECT pg_reload_conf()" >/dev/null
    compose up -d; compose restart nginx
    echo "Restored $dir${target:+ to $target}. Search index rebuilds in the background (fulltext service)."
    ;;

  # nginx caches upstream container IPs at start; recreated services get new IPs, so restart it after `up`.
  up) compose "$@"; compose restart nginx ;;

  *) compose "$@" ;;
esac
