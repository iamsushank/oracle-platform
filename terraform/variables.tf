variable "tenancy_ocid" {
  description = "OCI tenancy OCID (Oracle Cloud Console → Tenancy details)."
  type        = string
}

variable "user_ocid" {
  description = "OCI user OCID for the API key used by Terraform."
  type        = string
}

variable "fingerprint" {
  description = "API key fingerprint."
  type        = string
}

variable "private_key_path" {
  description = "Path to the OCI API private key PEM file (laptop use)."
  type        = string
  default     = "~/.oci/oci_api_key.pem"
}

variable "private_key" {
  description = "OCI API private key PEM contents (CI use via TF_VAR_private_key). Takes precedence over private_key_path."
  type        = string
  default     = ""
  sensitive   = true
}

variable "region" {
  description = "OCI region, e.g. ap-mumbai-1."
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment OCID where resources are created (root compartment is fine for free tier)."
  type        = string
}

variable "instance_name" {
  description = "Compute instance display name."
  type        = string
  default     = "platform"
}

variable "ssh_public_key" {
  description = "SSH public key for the ubuntu user (your laptop key)."
  type        = string
}

variable "deploy_ssh_public_key" {
  description = "SSH public key for the deploy user (GitHub Actions). Defaults to ssh_public_key."
  type        = string
  default     = ""
}

variable "admin_cidr" {
  description = "CIDR allowed to SSH (use your IP/32 for tighter security)."
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_shape" {
  description = "Compute shape. Default is AMD Always Free (x86). Use VM.Standard.A1.Flex for Ampere ARM."
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

variable "shape_ocpus" {
  description = "OCPUs for Flex shapes only (ignored by fixed shapes like E2.1.Micro)."
  type        = number
  default     = 1
}

variable "shape_memory_gb" {
  description = "Memory in GB for Flex shapes only (ignored by fixed shapes like E2.1.Micro)."
  type        = number
  default     = 6
}

variable "platform_hostname" {
  description = "Hostname set on the VM."
  type        = string
  default     = "platform"
}
