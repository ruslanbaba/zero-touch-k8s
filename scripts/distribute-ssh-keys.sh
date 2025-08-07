#!/bin/bash
# Distribute SSH keys to all factory floor nodes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="${HOME}/.ssh/factory_rsa.pub"
ANSIBLE_INVENTORY="${SCRIPT_DIR}/../ansible/inventory.yml"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check if SSH key exists
if [[ ! -f "$SSH_KEY" ]]; then
    error "SSH public key not found at $SSH_KEY. Please generate it first with: ssh-keygen -t rsa -b 4096 -f ~/.ssh/factory_rsa -N ''"
fi

# Check if Ansible inventory exists
if [[ ! -f "$ANSIBLE_INVENTORY" ]]; then
    error "Ansible inventory not found at $ANSIBLE_INVENTORY"
fi

info "Starting SSH key distribution to factory floor nodes..."

# Extract all IP addresses from inventory
FACTORY_IPS=$(python3 -c "
import yaml
import sys

with open('$ANSIBLE_INVENTORY', 'r') as f:
    inventory = yaml.safe_load(f)

def extract_ips(data, ips=None):
    if ips is None:
        ips = set()
    
    if isinstance(data, dict):
        if 'ansible_host' in data:
            ips.add(data['ansible_host'])
        for value in data.values():
            extract_ips(value, ips)
    elif isinstance(data, list):
        for item in data:
            extract_ips(item, ips)
    
    return ips

ips = extract_ips(inventory)
for ip in sorted(ips):
    print(ip)
")

if [[ -z "$FACTORY_IPS" ]]; then
    error "No IP addresses found in inventory file"
fi

# Count total nodes
TOTAL_NODES=$(echo "$FACTORY_IPS" | wc -l)
info "Found $TOTAL_NODES nodes in inventory"

# Function to distribute key to a single node
distribute_to_node() {
    local ip=$1
    local retries=3
    local delay=5
    
    for ((i=1; i<=retries; i++)); do
        if ssh-copy-id -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no admin@"$ip" >/dev/null 2>&1; then
            echo "✓ $ip"
            return 0
        else
            if [[ $i -lt $retries ]]; then
                echo "⚠ $ip (retry $i/$retries)"
                sleep $delay
            else
                echo "✗ $ip (failed after $retries attempts)"
                return 1
            fi
        fi
    done
}

# Distribute keys in parallel
info "Distributing SSH keys (this may take a few minutes)..."
echo "Legend: ✓ Success, ⚠ Retry, ✗ Failed"

# Use GNU parallel if available, otherwise use xargs
if command -v parallel >/dev/null 2>&1; then
    export -f distribute_to_node
    export SSH_KEY
    echo "$FACTORY_IPS" | parallel -j 20 distribute_to_node {}
else
    echo "$FACTORY_IPS" | xargs -n 1 -P 20 -I {} bash -c 'distribute_to_node "$@"' _ {}
fi

# Verify SSH connectivity
info "Verifying SSH connectivity to all nodes..."
FAILED_NODES=()

while IFS= read -r ip; do
    if ! ssh -i "${SSH_KEY%.pub}" -o ConnectTimeout=5 -o StrictHostKeyChecking=no admin@"$ip" "exit 0" >/dev/null 2>&1; then
        FAILED_NODES+=("$ip")
    fi
done <<< "$FACTORY_IPS"

if [[ ${#FAILED_NODES[@]} -eq 0 ]]; then
    info "✅ SSH key distribution completed successfully!"
    info "All $TOTAL_NODES factory nodes are accessible via SSH"
else
    warning "❌ Failed to establish SSH connectivity to ${#FAILED_NODES[@]} nodes:"
    printf '%s\n' "${FAILED_NODES[@]}"
    echo ""
    echo "Please check the following for failed nodes:"
    echo "1. Network connectivity"
    echo "2. SSH service is running"
    echo "3. User 'admin' exists with sudo privileges"
    echo "4. Firewall allows SSH (port 22)"
    exit 1
fi

# Test Ansible connectivity
info "Testing Ansible connectivity..."
if ansible all -i "$ANSIBLE_INVENTORY" -m ping >/dev/null 2>&1; then
    info "✅ Ansible connectivity verified!"
    info "Ready to proceed with factory cluster deployment"
else
    warning "❌ Ansible connectivity test failed"
    echo "Run the following command to debug:"
    echo "ansible all -i $ANSIBLE_INVENTORY -m ping"
    exit 1
fi

info "🎉 SSH key distribution completed successfully!"
echo ""
echo "Next steps:"
echo "1. Run: cd $(dirname "$SCRIPT_DIR")"
echo "2. Run: ./scripts/bootstrap-factory-k8s.sh"
echo "3. Monitor deployment progress in the logs"
