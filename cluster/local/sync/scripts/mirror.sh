#!/bin/sh -eu

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
