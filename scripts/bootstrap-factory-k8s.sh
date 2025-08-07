#!/bin/bash
# Factory Floor Kubernetes Cluster Bootstrap Script
# This script initializes the entire factory floor Kubernetes infrastructure

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="${SCRIPT_DIR}/../ansible"
LOG_FILE="/var/log/factory-k8s-bootstrap.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    log "${RED}ERROR: $1${NC}"
    exit 1
}

warning() {
    log "${YELLOW}WARNING: $1${NC}"
}

info() {
    log "${BLUE}INFO: $1${NC}"
}

success() {
    log "${GREEN}SUCCESS: $1${NC}"
}

# Check prerequisites
check_prerequisites() {
    info "Checking prerequisites..."
    
    # Check if running as root
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root"
    fi
    
    # Check if Ansible is installed
    if ! command -v ansible-playbook &> /dev/null; then
        warning "Ansible not found. Installing..."
        sudo apt-get update
        sudo apt-get install -y ansible python3-pip
        pip3 install --user ansible-core
    fi
    
    # Check if SSH key exists
    if [[ ! -f ~/.ssh/factory_rsa ]]; then
        warning "SSH key not found. Generating..."
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/factory_rsa -N ""
        success "SSH key generated at ~/.ssh/factory_rsa"
    fi
    
    # Check if inventory file exists
    if [[ ! -f "${ANSIBLE_DIR}/inventory.yml" ]]; then
        error "Ansible inventory file not found at ${ANSIBLE_DIR}/inventory.yml"
    fi
    
    success "Prerequisites check completed"
}

# Phase 1: Prepare infrastructure
prepare_infrastructure() {
    info "Phase 1: Preparing factory infrastructure..."
    
    # Distribute SSH keys to all nodes
    info "Distributing SSH keys to factory workstations..."
    "${SCRIPT_DIR}/distribute-ssh-keys.sh"
    
    # Verify connectivity to all nodes
    info "Verifying connectivity to all factory nodes..."
    ansible all -i "${ANSIBLE_DIR}/inventory.yml" -m ping --private-key ~/.ssh/factory_rsa
    
    success "Infrastructure preparation completed"
}

# Phase 2: Deploy registry and mirrors
deploy_registry() {
    info "Phase 2: Deploying container registry and Helm mirrors..."
    
    ansible-playbook -i "${ANSIBLE_DIR}/inventory.yml" \
        "${ANSIBLE_DIR}/site.yml" \
        --private-key ~/.ssh/factory_rsa \
        --limit "offline_registry" \
        --tags "registry,helm_mirror"
    
    success "Registry and mirrors deployment completed"
}

# Phase 3: Install and configure RKE2 masters
deploy_masters() {
    info "Phase 3: Deploying RKE2 master nodes..."
    
    ansible-playbook -i "${ANSIBLE_DIR}/inventory.yml" \
        "${ANSIBLE_DIR}/site.yml" \
        --private-key ~/.ssh/factory_rsa \
        --limit "masters" \
        --tags "os_update,rke2_install,rke2_master"
    
    success "RKE2 masters deployment completed"
}

# Phase 4: Install and configure RKE2 workers (in batches)
deploy_workers() {
    info "Phase 4: Deploying RKE2 worker nodes in batches..."
    
    # Deploy workers by production line to minimize downtime
    for line in A B C D; do
        info "Deploying production line ${line} workstations..."
        
        ansible-playbook -i "${ANSIBLE_DIR}/inventory.yml" \
            "${ANSIBLE_DIR}/site.yml" \
            --private-key ~/.ssh/factory_rsa \
            --limit "line-${line,,}-ws-*" \
            --tags "os_update,rke2_install,rke2_worker" \
            --serial 10
        
        success "Production line ${line} deployment completed"
        
        # Wait 5 minutes between production lines
        if [[ "$line" != "D" ]]; then
            info "Waiting 5 minutes before next production line..."
            sleep 300
        fi
    done
    
    success "All worker nodes deployment completed"
}

# Phase 5: Deploy factory applications
deploy_applications() {
    info "Phase 5: Deploying factory applications..."
    
    ansible-playbook -i "${ANSIBLE_DIR}/inventory.yml" \
        "${ANSIBLE_DIR}/site.yml" \
        --private-key ~/.ssh/factory_rsa \
        --limit "workers" \
        --tags "factory_apps"
    
    success "Factory applications deployment completed"
}

# Phase 6: Configure Anthos Config Management
configure_anthos() {
    info "Phase 6: Configuring Anthos Config Management..."
    
    ansible-playbook -i "${ANSIBLE_DIR}/inventory.yml" \
        "${ANSIBLE_DIR}/site.yml" \
        --private-key ~/.ssh/factory_rsa \
        --limit "masters[0]" \
        --tags "anthos_config"
    
    success "Anthos Config Management configuration completed"
}

# Phase 7: Verify deployment
verify_deployment() {
    info "Phase 7: Verifying factory floor deployment..."
    
    # Get master node IP
    MASTER_IP=$(ansible masters[0] -i "${ANSIBLE_DIR}/inventory.yml" --private-key ~/.ssh/factory_rsa -m debug -a "var=ansible_default_ipv4.address" | grep -o '".*"' | tr -d '"')
    
    # Copy kubeconfig
    scp -i ~/.ssh/factory_rsa admin@"${MASTER_IP}":/etc/rancher/rke2/rke2.yaml ./kubeconfig
    sed -i "s/127.0.0.1/${MASTER_IP}/g" ./kubeconfig
    export KUBECONFIG="./kubeconfig"
    
    # Check cluster status
    info "Checking cluster status..."
    kubectl get nodes -o wide
    
    # Check factory applications
    info "Checking factory applications..."
    kubectl get pods -n factory-apps -o wide
    
    # Check Config Sync status
    info "Checking Anthos Config Sync status..."
    kubectl get configmanagement -n config-management-system
    
    success "Deployment verification completed"
}

# Main execution
main() {
    info "Starting Zero-Touch Factory Floor Kubernetes Deployment"
    info "Deployment will be logged to: $LOG_FILE"
    
    check_prerequisites
    prepare_infrastructure
    deploy_registry
    deploy_masters
    deploy_workers
    deploy_applications
    configure_anthos
    verify_deployment
    
    success "🎉 Factory Floor Kubernetes deployment completed successfully!"
    info "Cluster kubeconfig saved to: ./kubeconfig"
    info "Access your cluster with: export KUBECONFIG=./kubeconfig"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
