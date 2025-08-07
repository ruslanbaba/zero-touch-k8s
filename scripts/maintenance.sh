#!/bin/bash
# Maintenance script for factory floor Kubernetes clusters
# Handles OS patching, certificate rotation, and application updates

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="${SCRIPT_DIR}/../ansible"
LOG_FILE="/var/log/factory-k8s-maintenance.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

info() {
    log "${BLUE}INFO: $1${NC}"
}

success() {
    log "${GREEN}SUCCESS: $1${NC}"
}

warning() {
    log "${YELLOW}WARNING: $1${NC}"
}

error() {
    log "${RED}ERROR: $1${NC}"
    exit 1
}

# Check if maintenance window is active
check_maintenance_window() {
    local current_hour=$(date +%H)
    local current_day=$(date +%u)  # 1=Monday, 7=Sunday
    
    # Maintenance window: Sunday 2-6 AM
    if [[ $current_day -eq 7 ]] && [[ $current_hour -ge 2 ]] && [[ $current_hour -lt 6 ]]; then
        return 0
    else
        warning "Current time is outside maintenance window (Sunday 2-6 AM)"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error "Maintenance cancelled by user"
        fi
    fi
}

# Drain factory line for maintenance
drain_production_line() {
    local line=$1
    info "Draining production line $line for maintenance..."
    
    # Get kubeconfig
    local master_ip=$(ansible masters[0] -i "${ANSIBLE_DIR}/inventory.yml" --private-key ~/.ssh/factory_rsa -m debug -a "var=ansible_default_ipv4.address" | grep -o '".*"' | tr -d '"')
    scp -i ~/.ssh/factory_rsa admin@"${master_ip}":/etc/rancher/rke2/rke2.yaml ./kubeconfig
    sed -i "s/127.0.0.1/${master_ip}/g" ./kubeconfig
    export KUBECONFIG="./kubeconfig"
    
    # Drain nodes in production line
    kubectl get nodes -l production-line=$line -o name | while read -r node; do
        info "Draining $node..."
        kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force --grace-period=300
    done
    
    success "Production line $line drained successfully"
}

# Uncordon factory line after maintenance
uncordon_production_line() {
    local line=$1
    info "Uncordoning production line $line after maintenance..."
    
    kubectl get nodes -l production-line=$line -o name | while read -r node; do
        info "Uncordoning $node..."
        kubectl uncordon "$node"
    done
    
    success "Production line $line uncordoned successfully"
}

# Perform OS patching on a production line
patch_production_line() {
    local line=$1
    info "Patching OS on production line $line..."
    
    # Drain the line first
    drain_production_line "$line"
    
    # Run OS patching playbook
    ansible-playbook -i "${ANSIBLE_DIR}/inventory.yml" \
        "${ANSIBLE_DIR}/site.yml" \
        --private-key ~/.ssh/factory_rsa \
        --limit "line-${line,,}-ws-*" \
        --tags "os_patching" \
        --extra-vars "maintenance_window=true"
    
    # Wait for nodes to come back online
    info "Waiting for nodes to come back online..."
    sleep 300
    
    # Verify all nodes are ready
    local ready_count=0
    local total_count=$(kubectl get nodes -l production-line=$line --no-headers | wc -l)
    
    while [[ $ready_count -lt $total_count ]]; do
        ready_count=$(kubectl get nodes -l production-line=$line --no-headers | grep -c " Ready " || true)
        info "Ready nodes: $ready_count/$total_count"
        sleep 30
    done
    
    # Uncordon the line
    uncordon_production_line "$line"
    
    success "Production line $line patching completed"
}

# Update factory applications
update_factory_applications() {
    info "Updating factory applications to latest versions..."
    
    # Update application images in the registry
    ansible-playbook -i "${ANSIBLE_DIR}/inventory.yml" \
        "${ANSIBLE_DIR}/site.yml" \
        --private-key ~/.ssh/factory_rsa \
        --limit "offline_registry" \
        --tags "app_updates"
    
    # Rolling update of applications
    kubectl rollout restart daemonset/quality-control -n factory-apps
    kubectl rollout restart daemonset/assembly-monitor -n factory-apps
    kubectl rollout restart daemonset/test-automation -n factory-apps
    kubectl rollout restart daemonset/packaging-automation -n factory-apps
    
    # Wait for rollouts to complete
    kubectl rollout status daemonset/quality-control -n factory-apps --timeout=600s
    kubectl rollout status daemonset/assembly-monitor -n factory-apps --timeout=600s
    kubectl rollout status daemonset/test-automation -n factory-apps --timeout=600s
    kubectl rollout status daemonset/packaging-automation -n factory-apps --timeout=600s
    
    success "Factory applications updated successfully"
}

# Rotate certificates
rotate_certificates() {
    info "Rotating Kubernetes certificates..."
    
    # Rotate RKE2 certificates
    ansible masters -i "${ANSIBLE_DIR}/inventory.yml" \
        --private-key ~/.ssh/factory_rsa \
        -m shell \
        -a "rke2 certificate rotate --all"
    
    # Restart RKE2 services
    ansible masters -i "${ANSIBLE_DIR}/inventory.yml" \
        --private-key ~/.ssh/factory_rsa \
        -m systemd \
        -a "name=rke2-server state=restarted" \
        --become
    
    success "Certificate rotation completed"
}

# Backup etcd
backup_etcd() {
    info "Creating etcd backup..."
    
    ansible masters[0] -i "${ANSIBLE_DIR}/inventory.yml" \
        --private-key ~/.ssh/factory_rsa \
        -m shell \
        -a "rke2 etcd-snapshot save --name factory-backup-$(date +%Y%m%d-%H%M%S)" \
        --become
    
    success "etcd backup created"
}

# Full maintenance cycle
full_maintenance() {
    info "Starting full factory maintenance cycle..."
    
    check_maintenance_window
    backup_etcd
    
    # Patch each production line sequentially
    for line in A B C D; do
        info "Starting maintenance for production line $line..."
        patch_production_line "$line"
        
        # 30-minute gap between lines for monitoring
        if [[ "$line" != "D" ]]; then
            info "Waiting 30 minutes before next production line..."
            sleep 1800
        fi
    done
    
    update_factory_applications
    rotate_certificates
    
    success "Full factory maintenance cycle completed!"
}

# Show usage
usage() {
    echo "Usage: $0 {full|patch-line|update-apps|backup|rotate-certs} [line]"
    echo "  full          - Run complete maintenance cycle"
    echo "  patch-line    - Patch specific production line (A, B, C, or D)"
    echo "  update-apps   - Update factory applications only"
    echo "  backup        - Create etcd backup"
    echo "  rotate-certs  - Rotate Kubernetes certificates"
    echo ""
    echo "Examples:"
    echo "  $0 full                    # Full maintenance cycle"
    echo "  $0 patch-line A            # Patch production line A only"
    echo "  $0 update-apps             # Update applications only"
    exit 1
}

# Main function
main() {
    local action=${1:-}
    local line=${2:-}
    
    case $action in
        full)
            full_maintenance
            ;;
        patch-line)
            if [[ -z "$line" ]]; then
                error "Production line required (A, B, C, or D)"
            fi
            check_maintenance_window
            patch_production_line "$line"
            ;;
        update-apps)
            update_factory_applications
            ;;
        backup)
            backup_etcd
            ;;
        rotate-certs)
            check_maintenance_window
            rotate_certificates
            ;;
        *)
            usage
            ;;
    esac
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
