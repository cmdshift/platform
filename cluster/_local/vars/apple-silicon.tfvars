platform = "macos"

libvirt_uri         = "qemu:///system?socket=/opt/homebrew/var/run/libvirt/libvirt-sock"
image_arch          = "arm64"
domain_type         = "hvf"
machine_arch        = "aarch64"
machine_type        = "virt"
uefi_loader         = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
uefi_nvram_template = "/opt/homebrew/share/qemu/edk2-arm-vars.fd"

ctrl_nodes             = 2
work_nodes             = 2
ctrl_memory_megabytes  = 4096
work_memory_megabytes  = 4096
infra_memory_megabytes = 4096
ctrl_vcpus             = 2
work_vcpus             = 2
infra_vcpus            = 2
