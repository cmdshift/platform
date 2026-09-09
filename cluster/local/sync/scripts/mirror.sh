#!/bin/sh -eu

# Full re-mirror every 5s instead of inotify (cmdshift/platform#55): macOS
# bind mounts drop inotify events (deletes and edits alike), and one dropped
# event wedged the pipeline until a manual container restart. The --remove
# mirror self-heals every pass; ≤5s sync latency is invisible (the Bucket
# source polls at 5m and sync_wait + flux_wait --with-source force an
# immediate pull). The container has no restart policy, so failures stay
# in-loop and logged (stdout is dropped — both rc calls print a success
# line every pass); stderr surfaces the failure.

while :; do
  if rc alias set main "$RUSTFS_ENDPOINT" "$RUSTFS_ACCESS_KEY" "$RUSTFS_SECRET_KEY" >/dev/null \
    && rc mirror --overwrite --remove /tmp/manifests/ "main/$RUSTFS_BUCKET/manifests/" >/dev/null
  then
    :
  else
    echo "mirror failed; retrying" >&2
  fi
  sleep 5
done
