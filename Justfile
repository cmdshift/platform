[private]
default:
  @just --list --unsorted --list-heading '' --list-prefix ''

init *args:
  packer init cluster/cloud/image
  terraform -chdir=cluster/local init {{args}}
  terraform -chdir=cluster/local/bootstrap init {{args}}

cluster action *args:
  terraform -chdir=cluster/local {{action}} {{args}}

bootstrap action *args:
  terraform -chdir=cluster/local/bootstrap {{action}} {{args}}

code *args:
  doppler run -- opencode {{args}}

image:
  packer build cluster/cloud/image
