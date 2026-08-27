[private]
default:
  @just --list --unsorted --list-heading '' --list-prefix ''

certs:
  step certificate create "platform-intermediate" $STEPPATH/intermediate_ca.crt $STEPPATH/intermediate_ca.key \
    --profile intermediate-ca \
    --ca $STEPPATH/root_ca.crt \
    --ca-key $STEPPATH/root_ca.key \
    --not-after 8760h \
    --no-password \
    --insecure

init *args:
  packer init cluster/cloud/image
  terraform -chdir=cluster/local init {{args}}
  terraform -chdir=cluster/local/bootstrap init {{args}}

plan *args:
  terraform -chdir=cluster/local plan {{args}}

apply *args:
  terraform -chdir=cluster/local apply {{args}}

destroy *args:
  terraform -chdir=cluster/local destroy {{args}}

bootstrap *args:
  terraform -chdir=cluster/local/bootstrap {{args}}

image:
  packer build cluster/cloud/image
