#!/bin/sh

set -eu

healthcheck() {
  rc alias set main http://localhost:9000 "rustfsadmin" "rustfsadmin"
  rc ready main
}

healthcheck "$@"
