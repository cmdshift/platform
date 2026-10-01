host_os = "linux"

libvirt_uri         = "qemu:///system"
image_arch          = "amd64"
domain_type         = "kvm"
machine_arch        = "x86_64"
machine_type        = "q35"
uefi_loader         = "/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd"
uefi_nvram_template = "/usr/share/edk2/x64/OVMF_VARS.4m.fd"

ctrl_nodes   = 3
work_nodes   = 4
ctrl_memory  = 6144
work_memory  = 4096
infra_memory = 8192
ctrl_vcpus   = 2
work_vcpus   = 4
infra_vcpus  = 4
