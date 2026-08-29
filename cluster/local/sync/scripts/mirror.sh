#!/bin/sh -eu

rc alias set main "$RUSTFS_ENDPOINT" "$RUSTFS_ACCESS_KEY" "$RUSTFS_SECRET_KEY"

sync() {
  rc mirror --overwrite /tmp/manifests/ "main/$RUSTFS_BUCKET/manifests/"
}

mirror() {
  echo "Watching for changes in /tmp/manifests..."
  sync
  inotifywait -m -r -e create,delete,modify,move /tmp/manifests | while read -r _ event file; do
    echo "Detected $event on $file. Syncing..."
    sync
  done
}

mirror "$@"
