variable "org_name" {
  type        = string
  description = "The name of your Chainguard organization. For instance: 'your.org.com'."
}

variable "ce_types" {
  type        = list(string)
  description = "Optional list of CloudEvents types to process. Events with a Ce-Type not in this list will be ignored. If empty, all event types are processed."
  default     = []
}
