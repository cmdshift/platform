[private]
default:
  @just --list --unsorted --list-heading '' --list-prefix ''

code *args:
  doppler run -- opencode {{args}}
