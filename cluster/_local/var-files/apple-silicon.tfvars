host_os = "macos"

libvirt_uri         = "qemu:///system?socket=/opt/homebrew/var/run/libvirt/libvirt-sock"
image_arch          = "arm64"
domain_type         = "hvf"
machine_arch        = "aarch64"
machine_type        = "virt"
uefi_loader         = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
uefi_nvram_template = "/opt/homebrew/share/qemu/edk2-aarch64-vars.fd"

ctrl_nodes   = 2
work_nodes   = 2
ctrl_memory  = 4096
work_memory  = 2048
infra_memory = 4096
ctrl_vcpus   = 2
work_vcpus   = 2
infra_vcpus  = 2
