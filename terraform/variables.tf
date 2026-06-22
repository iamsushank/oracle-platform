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
  description = "Path to the OCI API private key PEM file."
  type        = string
  default     = "~/.oci/oci_api_key.pem"
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

variable "shape_ocpus" {
  description = "Ampere A1 OCPUs (free tier allows up to 4 total across all A1 VMs)."
  type        = number
  default     = 2
}

variable "shape_memory_gb" {
  description = "Ampere A1 memory in GB."
  type        = number
  default     = 12
}

variable "platform_hostname" {
  description = "Hostname set on the VM."
  type        = string
  default     = "platform"
}
