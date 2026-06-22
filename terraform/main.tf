data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

data "oci_core_images" "ubuntu_arm" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  ad_name              = data.oci_identity_availability_domains.ads.availability_domains[0].name
  ubuntu_image_id      = data.oci_core_images.ubuntu_arm.images[0].id
  deploy_ssh_public_key = var.deploy_ssh_public_key != "" ? var.deploy_ssh_public_key : var.ssh_public_key
  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    ssh_public_key        = var.ssh_public_key
    deploy_ssh_public_key = local.deploy_ssh_public_key
    hostname              = var.platform_hostname
  })
}

resource "oci_core_vcn" "platform" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "platform-vcn"
  dns_label      = "platform"
}

resource "oci_core_internet_gateway" "platform" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.platform.id
  display_name   = "platform-igw"
  enabled        = true
}

resource "oci_core_route_table" "platform" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.platform.id
  display_name   = "platform-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.platform.id
  }
}

resource "oci_core_security_list" "platform" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.platform.id
  display_name   = "platform-sl"

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "6"
    source   = var.admin_cidr
    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_subnet" "platform" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.platform.id
  cidr_block                 = "10.0.1.0/24"
  display_name               = "platform-subnet"
  dns_label                  = "platform"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.platform.id
  security_list_ids          = [oci_core_security_list.platform.id]
}

resource "oci_core_instance" "platform" {
  availability_domain = local.ad_name
  compartment_id      = var.compartment_ocid
  display_name        = var.instance_name
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.shape_ocpus
    memory_in_gbs = var.shape_memory_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.platform.id
    assign_public_ip = true
    hostname_label   = var.platform_hostname
  }

  source_details {
    source_type = "image"
    source_id   = local.ubuntu_image_id
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.cloud_init)
  }

  freeform_tags = {
    role = "platform"
  }
}

data "oci_core_vnic_attachments" "platform" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.platform.id
}

data "oci_core_vnic" "platform" {
  vnic_id = data.oci_core_vnic_attachments.platform.vnic_attachments[0].vnic_id
}

data "oci_core_private_ips" "platform" {
  vnic_id = data.oci_core_vnic.platform.id
}

data "oci_core_public_ips" "platform" {
  compartment_id = var.compartment_ocid
  private_ip_id  = data.oci_core_private_ips.platform.private_ips[0].id
}

locals {
  public_ip = data.oci_core_public_ips.platform.public_ips[0].ip_address
}
