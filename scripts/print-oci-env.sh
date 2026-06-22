#!/usr/bin/env bash
# Print OCIDs from OCI CLI config to paste into .env.platform
set -euo pipefail
CFG="${OCI_CONFIG_FILE:-$HOME/.oci/config}"
if [ ! -f "$CFG" ]; then
  echo "No $CFG — create API key in Oracle Console, then run:"
  echo "  oci setup config"
  exit 1
fi
echo "# Paste into .env.platform:"
echo "OCI_TENANCY_OCID=$(awk -F= '/^tenancy=/{print $2}' "$CFG" | tr -d ' ')"
echo "OCI_USER_OCID=$(awk -F= '/^user=/{print $2}' "$CFG" | tr -d ' ')"
echo "OCI_FINGERPRINT=$(awk -F= '/^fingerprint=/{print $2}' "$CFG" | tr -d ' ')"
echo "OCI_REGION=$(awk -F= '/^region=/{print $2}' "$CFG" | tr -d ' ')"
echo "OCI_PRIVATE_KEY_PATH=$(awk -F= '/^key_file=/{print $2}' "$CFG" | tr -d ' ')"
echo "OCI_COMPARTMENT_OCID=$(awk -F= '/^tenancy=/{print $2}' "$CFG" | tr -d ' ')"
echo "OCI_USE_LOCAL_CONFIG=true"
