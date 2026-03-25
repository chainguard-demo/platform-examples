output "url" {
  value       = "https://${azurerm_container_app.image_copy.ingress[0].fqdn}"
  description = "Public URL for the image-copy service."
}

output "dst_repo" {
  value       = var.dst_repo
  description = "Destination repo prefix in ACR."
}
