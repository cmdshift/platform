#!/bin/sh

set -eu

healthcheck() {
  endpoint="$1"
  access_key_id="$2"
  secret_access_key="$3"

  shift 3

  rc alias set main "$endpoint" "$access_key_id" "$secret_access_key"

  for bucket in "$@"; do
    rc mb --ignore-existing "main/$bucket" > /dev/null
  done
}

healthcheck "$@"