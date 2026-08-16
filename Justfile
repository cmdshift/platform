[private]
default:
  @just --list --unsorted --list-heading '' --list-prefix ''

init *args:
  packer init cluster/cloud/image
  terraform -chdir=cluster/local init {{args}}

plan *args:
  terraform -chdir=cluster/local plan {{args}}

apply *args:
  terraform -chdir=cluster/local apply {{args}}

destroy *args:
  terraform -chdir=cluster/local destroy {{args}}

image:
  packer build cluster/cloud/image