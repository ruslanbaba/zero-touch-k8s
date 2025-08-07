#!/bin/bash
# Infrastructure validation and drift detection script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="${SCRIPT_DIR}/../ansible"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

info() {
    log "${YELLOW}INFO: $1${NC}"
}

success() {
    log "${GREEN}SUCCESS: $1${NC}"
}

error() {
    log "${RED}ERROR: $1${NC}"
    exit 1
}

# Validate Ansible playbooks
validate_ansible() {
    info "Validating Ansible playbooks..."
    
    # Syntax check
    ansible-playbook --syntax-check "${ANSIBLE_DIR}/site.yml"
    
    # Lint check
    ansible-lint "${ANSIBLE_DIR}/site.yml" || error "Ansible lint failed"
    
    # Dry run validation
    ansible-playbook -i "${ANSIBLE_DIR}/inventory.yml" \
        "${ANSIBLE_DIR}/site.yml" \
        --check \
        --diff \
        --private-key ~/.ssh/factory_rsa
        
    success "Ansible validation completed"
}

# Validate Kubernetes manifests
validate_kubernetes() {
    info "Validating Kubernetes manifests..."
    
    # Validate with kubeval
    find apps/ -name "*.yaml" -o -name "*.yml" | xargs kubeval
    
    # Validate Helm charts
    helm lint helm-charts/factory-apps/
    helm template helm-charts/factory-apps/ | kubeval
    
    # OPA Gatekeeper policy validation
    conftest verify --policy anthos-config/policies/ apps/*/manifests/
    
    success "Kubernetes validation completed"
}

# Infrastructure drift detection
detect_drift() {
    info "Detecting infrastructure drift..."
    
    # Compare actual vs desired state
    ansible-playbook -i "${ANSIBLE_DIR}/inventory.yml" \
        "${ANSIBLE_DIR}/site.yml" \
        --check \
        --diff \
        --private-key ~/.ssh/factory_rsa \
        | tee drift-report.txt
        
    if grep -q "changed:" drift-report.txt; then
        error "Infrastructure drift detected! Check drift-report.txt"
    else
        success "No infrastructure drift detected"
    fi
}

# Compliance validation
validate_compliance() {
    info "Running compliance checks..."
    
    # CIS Kubernetes benchmark
    kube-bench run --targets node,master --json | tee cis-report.json
    
    # Custom compliance checks
    ansible-playbook -i "${ANSIBLE_DIR}/inventory.yml" \
        "${ANSIBLE_DIR}/compliance-check.yml" \
        --private-key ~/.ssh/factory_rsa
        
    success "Compliance validation completed"
}

# Main validation function
main() {
    case ${1:-all} in
        ansible)
            validate_ansible
            ;;
        kubernetes)
            validate_kubernetes
            ;;
        drift)
            detect_drift
            ;;
        compliance)
            validate_compliance
            ;;
        all)
            validate_ansible
            validate_kubernetes
            detect_drift
            validate_compliance
            ;;
        *)
            echo "Usage: $0 {ansible|kubernetes|drift|compliance|all}"
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
