output "group_repository_url" {
  description = "URL to use in /etc/apk/repositories. Point apk at this."
  value       = "${var.nexus_url}/repository/${sonatyperepo_repository_raw_group.group.name}"
}

output "packages_proxy_url" {
  description = "Direct URL of the packages proxy (for reference / debugging)"
  value       = "${var.nexus_url}/repository/${sonatyperepo_repository_raw_proxy.packages.name}"
}

output "index_proxy_url" {
  description = "Direct URL of the index proxy (for reference / debugging)"
  value       = "${var.nexus_url}/repository/${sonatyperepo_repository_raw_proxy.index.name}"
}
