output "resource_group" {
  value       = azurerm_resource_group.main.name
  description = "Generated resource group name."
}

output "new_acr_name" {
  value       = one(azurerm_container_registry.new[*].name)
  description = "Name of the newly created ACR. Use with 'az acr login --name' after the targeted apply. Null when reusing an existing ACR."
}

output "acr_login_server" {
  value       = local.acr_login_server
  description = "ACR login server hostname (e.g. myregistry.azurecr.io)."
}

output "acr_id" {
  value       = local.acr_id
  description = "Full Azure resource ID of the ACR."
}

output "dst_repo" {
  value       = "${local.acr_login_server}/${var.dst_repo_prefix}"
  description = "Destination repository prefix for copied images."
}

output "webhook_url" {
  value       = "https://${azurerm_container_app.replicator.ingress[0].fqdn}"
  description = "Public URL of the replicator Container App. This is the sink registered with the Chainguard subscription."
}

output "managed_identity_id" {
  value       = azurerm_user_assigned_identity.mi.id
  description = "Resource ID of the mi-cgr-acr-pushpull managed identity."
}

output "chainguard_identity_id" {
  value       = chainguard_identity.azure.id
  description = "Chainguard identity ID used by the Container App to authenticate with the Chainguard API."
}
