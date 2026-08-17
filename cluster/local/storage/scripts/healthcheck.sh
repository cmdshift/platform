#!/bin/sh

set -eu

healthcheck() {
  rc alias set main "$RUSTFS_ENDPOINT" "$RUSTFS_ACCESS_KEY" "$RUSTFS_SECRET_KEY"

  for bucket in "$@"; do
    rc mb --ignore-existing "main/$bucket" > /dev/null
  done
}

healthcheck "$@"