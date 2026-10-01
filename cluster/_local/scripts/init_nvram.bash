#!/usr/bin/env bash

set -euo pipefail

init_nvram() {
  template="$1"
  dir="$2"
  shift 2
  mkdir -p "$dir"
  for name in "$@"; do
    cp "$template" "${dir}/${name}_VARS.fd"
  done
}

init_nvram "$@"
