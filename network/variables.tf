variable "region" {
  description = "AWS region to deploy into (must match the region used in ../databricks-sra)."
  type        = string
}

variable "resource_prefix" {
  description = "Prefix for naming resources. Should match the resource_prefix used in ../databricks-sra."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.10.0.0/16"
}

variable "general_access_service_name" {
  description = "Databricks backend PrivateLink 'General Access' (REST API) endpoint service name for this region. Look up the value for your region in ../databricks-sra/variables.tf under general_access_config."
  type        = string
}

variable "scc_relay_service_name" {
  description = "Databricks backend PrivateLink 'SCC Relay' endpoint service name for this region. Look up the value for your region in ../databricks-sra/variables.tf under scc_relay_config."
  type        = string
}
