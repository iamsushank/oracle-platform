terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  user_ocid    = var.user_ocid
  fingerprint  = var.fingerprint
  region       = var.region

  # Prefer inline key content (CI: TF_VAR_private_key) over a file path (laptop).
  private_key      = var.private_key != "" ? var.private_key : null
  private_key_path = var.private_key != "" ? null : var.private_key_path
}
