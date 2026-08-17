[private]
default:
  @just --list --unsorted --list-heading '' --list-prefix ''

init *args:
  packer init cluster/cloud/image
  terraform -chdir=cluster/local init {{args}}
  mkcert -cert-file cluster/local/.tmp/tls.crt -key-file cluster/local/.tmp/tls.key \
    "cloud.test" \
    "*.cloud.test" && \
  cat cluster/local/.tmp/tls.crt cluster/local/.tmp/tls.key > cluster/local/.tmp/tls.pem

plan *args:
  terraform -chdir=cluster/local plan {{args}}

apply *args:
  terraform -chdir=cluster/local apply {{args}}

destroy *args:
  terraform -chdir=cluster/local destroy {{args}}

image:
  packer build cluster/cloud/image
