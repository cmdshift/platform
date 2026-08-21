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
  
  step certificate create "cloud-test" $STEPPATH/tls.crt $STEPPATH/tls.key \
    --profile leaf \
    --ca $STEPPATH/intermediate_ca.crt \
    --ca-key $STEPPATH/intermediate_ca.key \
    --not-after 8760h \
    --san "cloud.test" \
    --san "*.cloud.test" \
    --no-password \
    --insecure

  cat $STEPPATH/tls.crt $STEPPATH/intermediate_ca.crt $STEPPATH/tls.key > $STEPPATH/tls.pem

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
