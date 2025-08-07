#!/bin/bash
# Automated security scanning and compliance checking

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTS_DIR="/opt/security-reports"
TRIVY_DB_DIR="/opt/trivy-db"

# Initialize security scanning
init_security_tools() {
    info "Initializing security scanning tools..."
    
    # Update Trivy database
    trivy image --download-db-only --cache-dir "$TRIVY_DB_DIR"
    
    # Update CIS benchmarks
    kube-bench --check 1.6.1 --benchmark cis-1.6 --json > /tmp/kube-bench-update.json
    
    # Initialize Falco rules
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: falco-rules
  namespace: security-system
data:
  factory_rules.yaml: |
    - rule: Unauthorized Process in Factory Container
      desc: Detect unauthorized processes in factory workloads
      condition: >
        spawned_process and
        container and
        k8s.ns.name="factory-apps" and
        not proc.name in (factory_allowed_processes)
      output: >
        Unauthorized process in factory container
        (user=%user.name command=%proc.cmdline container=%container.name
        k8s.pod=%k8s.pod.name)
      priority: HIGH
      
    - rule: Factory Network Connection
      desc: Monitor factory workload network connections
      condition: >
        inbound_outbound and
        k8s.ns.name="factory-apps" and
        not fd.name in (factory_allowed_ips)
      output: >
        Unexpected network connection from factory workload
        (src_ip=%fd.cip dest_ip=%fd.sip k8s.pod=%k8s.pod.name)
      priority: MEDIUM
      
    - list: factory_allowed_processes
      items: [factory-app, nginx, monitoring-agent]
      
    - list: factory_allowed_ips
      items: [192.168.101.0/24, 192.168.102.0/24, 192.168.103.0/24, 192.168.104.0/24]
EOF
    
    success "Security tools initialized"
}

# Container image vulnerability scanning
scan_container_images() {
    info "Scanning container images for vulnerabilities..."
    
    local registry_url="factory-registry.local:5000"
    local scan_report="${REPORTS_DIR}/container-scan-$(date +%Y%m%d).json"
    
    # Get all images from registry
    local images=$(curl -s "http://${registry_url}/v2/_catalog" | jq -r '.repositories[]')
    
    mkdir -p "$REPORTS_DIR"
    echo '{"scans": []}' > "$scan_report"
    
    for image in $images; do
        info "Scanning image: $image"
        
        # Get latest tag
        local tag=$(curl -s "http://${registry_url}/v2/${image}/tags/list" | jq -r '.tags[0]')
        local full_image="${registry_url}/${image}:${tag}"
        
        # Run Trivy scan
        trivy image --format json --cache-dir "$TRIVY_DB_DIR" "$full_image" > "/tmp/${image}-scan.json"
        
        # Merge results
        jq --slurpfile scan "/tmp/${image}-scan.json" \
           '.scans += $scan' "$scan_report" > "/tmp/merged-scan.json"
        mv "/tmp/merged-scan.json" "$scan_report"
        
        # Check for critical vulnerabilities
        local critical_count=$(jq '.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL") | length' "/tmp/${image}-scan.json" | wc -l)
        
        if [[ $critical_count -gt 0 ]]; then
            warning "Critical vulnerabilities found in $full_image: $critical_count"
            
            # Create Kubernetes event
            kubectl create event "security-alert" \
                --type="Warning" \
                --reason="CriticalVulnerability" \
                --message="Critical vulnerabilities found in $full_image" \
                --namespace="security-system" || true
        fi
    done
    
    success "Container image scanning completed: $scan_report"
}

# Runtime security monitoring
monitor_runtime_security() {
    info "Monitoring runtime security events..."
    
    # Check Falco alerts
    kubectl logs -n security-system deployment/falco --since=1h | \
        grep -E "(CRITICAL|HIGH|MEDIUM)" > "${REPORTS_DIR}/falco-alerts-$(date +%Y%m%d-%H).log" || true
    
    # Network policy violations
    kubectl get events --all-namespaces --field-selector type=Warning,reason=NetworkPolicyViolation \
        --sort-by='.lastTimestamp' > "${REPORTS_DIR}/networkpolicy-violations-$(date +%Y%m%d).log"
    
    # Pod security violations
    kubectl get events --all-namespaces --field-selector type=Warning,reason=SecurityPolicyViolation \
        --sort-by='.lastTimestamp' > "${REPORTS_DIR}/podsecurity-violations-$(date +%Y%m%d).log"
    
    success "Runtime security monitoring completed"
}

# CIS Kubernetes benchmark
run_cis_benchmark() {
    info "Running CIS Kubernetes benchmark..."
    
    local cis_report="${REPORTS_DIR}/cis-benchmark-$(date +%Y%m%d).json"
    
    # Run on master nodes
    kube-bench run --targets master --benchmark cis-1.6 --json > "${cis_report}.master"
    
    # Run on worker nodes
    ansible workers -i "${SCRIPT_DIR}/../ansible/inventory.yml" \
        --private-key ~/.ssh/factory_rsa \
        -m shell -a "kube-bench run --targets node --benchmark cis-1.6 --json" \
        > "${cis_report}.workers"
    
    # Merge results
    jq -s 'add' "${cis_report}.master" "${cis_report}.workers" > "$cis_report"
    
    # Check compliance score
    local passed=$(jq '.Totals.total_pass' "$cis_report")
    local total=$(jq '.Totals.total_pass + .Totals.total_fail + .Totals.total_warn' "$cis_report")
    local score=$(echo "scale=2; $passed * 100 / $total" | bc)
    
    info "CIS Kubernetes Benchmark Score: ${score}%"
    
    if (( $(echo "$score < 95.0" | bc -l) )); then
        warning "CIS compliance score below 95%: ${score}%"
        
        # Generate remediation report
        jq '.Controls[] | select(.tests[].results[].status == "FAIL") | {id: .id, text: .text, remediation: .tests[].results[].remediation}' \
            "$cis_report" > "${REPORTS_DIR}/cis-remediation-$(date +%Y%m%d).json"
    fi
    
    success "CIS benchmark completed: $cis_report"
}

# GDPR/Data privacy compliance
check_data_privacy() {
    info "Checking data privacy compliance..."
    
    # Scan for potential PII in logs
    kubectl logs --all-containers --all-namespaces --since=24h | \
        grep -iE "(ssn|social.security|credit.card|email|phone)" > \
        "${REPORTS_DIR}/potential-pii-$(date +%Y%m%d).log" || true
    
    # Check encryption at rest
    kubectl get secrets --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.namespace}{"\t"}{.type}{"\n"}{end}' | \
        grep -v "kubernetes.io/service-account-token" > "${REPORTS_DIR}/secrets-audit-$(date +%Y%m%d).log"
    
    # Verify data retention policies
    kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.persistentVolumeReclaimPolicy}{"\n"}{end}' > \
        "${REPORTS_DIR}/data-retention-$(date +%Y%m%d).log"
    
    success "Data privacy compliance check completed"
}

# Generate security dashboard
generate_security_dashboard() {
    info "Generating security dashboard..."
    
    cat > "${REPORTS_DIR}/security-dashboard-$(date +%Y%m%d).html" <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Factory Kubernetes Security Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .metric { background: #f0f0f0; padding: 10px; margin: 10px 0; border-radius: 5px; }
        .critical { background: #ffebee; border-left: 5px solid #f44336; }
        .warning { background: #fff3e0; border-left: 5px solid #ff9800; }
        .success { background: #e8f5e8; border-left: 5px solid #4caf50; }
    </style>
</head>
<body>
    <h1>Factory Kubernetes Security Dashboard</h1>
    <p>Generated: $(date)</p>
    
    <div class="metric success">
        <h3>CIS Compliance Score</h3>
        <p>Current Score: $(jq '.Totals.total_pass * 100 / (.Totals.total_pass + .Totals.total_fail + .Totals.total_warn)' "${REPORTS_DIR}/cis-benchmark-$(date +%Y%m%d).json" 2>/dev/null || echo "N/A")%</p>
    </div>
    
    <div class="metric">
        <h3>Container Vulnerabilities</h3>
        <p>Critical: $(jq '[.scans[].Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "${REPORTS_DIR}/container-scan-$(date +%Y%m%d).json" 2>/dev/null || echo "0")</p>
        <p>High: $(jq '[.scans[].Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "${REPORTS_DIR}/container-scan-$(date +%Y%m%d).json" 2>/dev/null || echo "0")</p>
    </div>
    
    <div class="metric">
        <h3>Runtime Security Events</h3>
        <p>Falco Alerts (24h): $(wc -l < "${REPORTS_DIR}/falco-alerts-$(date +%Y%m%d-$(date +%H)).log" 2>/dev/null || echo "0")</p>
        <p>Network Policy Violations: $(wc -l < "${REPORTS_DIR}/networkpolicy-violations-$(date +%Y%m%d).log" 2>/dev/null || echo "0")</p>
    </div>
</body>
</html>
EOF

    success "Security dashboard generated: ${REPORTS_DIR}/security-dashboard-$(date +%Y%m%d).html"
}

# Main security function
main() {
    mkdir -p "$REPORTS_DIR"
    
    case ${1:-all} in
        init)
            init_security_tools
            ;;
        scan)
            scan_container_images
            ;;
        monitor)
            monitor_runtime_security
            ;;
        cis)
            run_cis_benchmark
            ;;
        privacy)
            check_data_privacy
            ;;
        dashboard)
            generate_security_dashboard
            ;;
        all)
            init_security_tools
            scan_container_images
            monitor_runtime_security
            run_cis_benchmark
            check_data_privacy
            generate_security_dashboard
            ;;
        *)
            echo "Usage: $0 {init|scan|monitor|cis|privacy|dashboard|all}"
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
