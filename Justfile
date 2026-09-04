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

cluster action *args:
  terraform -chdir=cluster/local {{action}} {{args}}

bootstrap action *args:
  terraform -chdir=cluster/local/bootstrap {{action}} {{args}}

code:
  doppler run -- opencode

image:
  packer build cluster/cloud/image
