#!/bin/sh -eu

mirror() {
  echo "Watching for changes in /tmp/manifests..."
  
  aws s3 sync /tmp/manifests "s3://$RUSTFS_BUCKET/manifests" \
    --endpoint-url "$RUSTFS_ENDPOINT" \
    --delete \
    --only-show-errors \
    --no-verify-ssl

  inotifywait -m -r -e create,delete,modify,move /tmp/manifests | while read -r directory event file; do
    echo "Detected $event on $file. Syncing..."
    
    aws s3 sync /tmp/manifests "s3://$RUSTFS_BUCKET/manifests" \
      --endpoint-url "$RUSTFS_ENDPOINT" \
      --delete \
      --only-show-errors \
      --no-verify-ssl
  done
}

mirror "$@"