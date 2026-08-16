[private]
default:
  @just --list --unsorted --list-heading '' --list-prefix ''

init *args:
  terraform -chdir=cluster/local init {{args}}

apply *args:
  terraform -chdir=cluster/local apply {{args}}

destroy *args:
  terraform -chdir=cluster/local destroy {{args}}