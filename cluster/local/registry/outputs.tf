output "push_identity" {
  value = {
    username = local.push_username
    password = random_password.push_password.result
  }
  sensitive = true
}
