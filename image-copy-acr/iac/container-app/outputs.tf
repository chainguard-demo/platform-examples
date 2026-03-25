output "container_app_url" {
  value       = azurerm_container_app.image_copy.ingress[0].fqdn
  description = "Public URL for the container app."
}
