output "instance_public_ip" {
  description = "Public IP — point DNS A record here; use for Ansible inventory."
  value       = local.public_ip
}

output "instance_ocid" {
  value = oci_core_instance.platform.id
}

output "ssh_command" {
  description = "SSH as ubuntu after cloud-init finishes (~2 min)."
  value       = "ssh ubuntu@${local.public_ip}"
}

output "ansible_inventory_hint" {
  value = <<-EOT
    Add to infra/ansible/inventory.yml:
      platform:
        hosts:
          oracle:
            ansible_host: ${local.public_ip}
            ansible_user: ubuntu
  EOT
}
