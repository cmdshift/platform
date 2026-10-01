resource "libvirt_pool" "talos" {
  name = "talos"
  type = "dir"
  target = {
    path = "${path.module}/.temp/storage"
  }
}
