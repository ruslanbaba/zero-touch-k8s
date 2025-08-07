# Deployment Guide

This comprehensive guide walks through the complete deployment process for the Zero-Touch Factory Floor Kubernetes solution.

## Prerequisites Checklist

### Hardware Preparation

#### Master Nodes (3 required)
- [ ] CPU: 8+ cores per node
- [ ] RAM: 16GB+ per node (32GB recommended)
- [ ] Storage: 500GB+ SSD per node
- [ ] Network: Dual 1Gbps NICs (recommended)
- [ ] IPMI/iDRAC access for remote management

#### Worker Nodes (200+ factory workstations)
- [ ] CPU: 4+ cores per node
- [ ] RAM: 8GB+ per node (16GB recommended)
- [ ] Storage: 100GB+ SSD per node
- [ ] Network: 1Gbps NIC
- [ ] Industrial hardware compatibility verified

#### Infrastructure Nodes (2 required)
- [ ] CPU: 4+ cores per node
- [ ] RAM: 8GB+ per node
- [ ] Storage: 1TB+ SSD per node
- [ ] Network: High-bandwidth connectivity

### Network Configuration

#### VLAN Setup
```bash
# Management VLAN
VLAN 100: 192.168.100.0/24 (Masters, Infrastructure)

# Production VLANs
VLAN 101: 192.168.101.0/24 (Line A - Quality Control)
VLAN 102: 192.168.102.0/24 (Line B - Assembly)
VLAN 103: 192.168.103.0/24 (Line C - Testing)
VLAN 104: 192.168.104.0/24 (Line D - Packaging)
```

#### Firewall Rules
```bash
# Kubernetes API (6443)
iptables -A INPUT -p tcp --dport 6443 -s 192.168.100.0/24 -j ACCEPT

# etcd (2379-2380)
iptables -A INPUT -p tcp --dport 2379:2380 -s 192.168.100.0/24 -j ACCEPT

# Kubelet API (10250)
iptables -A INPUT -p tcp --dport 10250 -s 192.168.0.0/16 -j ACCEPT

# NodePort range (30000-32767)
iptables -A INPUT -p tcp --dport 30000:32767 -s 192.168.0.0/16 -j ACCEPT
```

### Software Requirements

#### Control Node
```bash
# Install Ansible and dependencies
sudo apt update
sudo apt install -y ansible python3-pip openssh-client git

# Install additional Python packages
pip3 install --user jinja2 netaddr
```

#### Target Nodes
```bash
# All factory workstations need:
# - Ubuntu 20.04 LTS or RHEL 8+
# - SSH server enabled
# - Python3 installed
# - Sudo access for deployment user

# Verify on each node:
python3 --version
sudo -l
systemctl status ssh
```

## Phase 1: Environment Preparation

### 1.1 SSH Key Management

Generate and distribute SSH keys for secure access:

```bash
# Generate SSH key pair
ssh-keygen -t rsa -b 4096 -f ~/.ssh/factory_rsa -N ""

# Create key distribution script
cat > distribute-keys.sh << 'EOF'
#!/bin/bash
FACTORY_NODES=(
    "192.168.100.10"  # master-01
    "192.168.100.11"  # master-02
    "192.168.100.12"  # master-03
    "192.168.100.20"  # registry-01
    "192.168.100.21"  # registry-02
)

# Add production line nodes
for vlan in 101 102 103 104; do
    for host in {10..59}; do
        FACTORY_NODES+=("192.168.${vlan}.${host}")
    done
done

for node in "${FACTORY_NODES[@]}"; do
    echo "Copying key to $node..."
    ssh-copy-id -i ~/.ssh/factory_rsa.pub admin@$node
done
EOF

chmod +x distribute-keys.sh
./distribute-keys.sh
```

### 1.2 Inventory Configuration

Configure Ansible inventory with your factory network details:

```bash
# Edit ansible/inventory.yml
cat > ansible/inventory.yml << 'EOF'
---
all:
  vars:
    ansible_user: admin
    ansible_ssh_private_key_file: ~/.ssh/factory_rsa
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
    
  children:
    masters:
      hosts:
        factory-master-01:
          ansible_host: 192.168.100.10
          node_role: server
        factory-master-02:
          ansible_host: 192.168.100.11
          node_role: server
        factory-master-03:
          ansible_host: 192.168.100.12
          node_role: server
          
    workers:
      children:
        line_a:
          hosts:
            line-a-ws-[001:050]:
              ansible_host: 192.168.101.[10:59]
              node_role: agent
              production_line: A
              zone: quality-control
              
        line_b:
          hosts:
            line-b-ws-[001:050]:
              ansible_host: 192.168.102.[10:59]
              node_role: agent
              production_line: B
              zone: assembly
              
        line_c:
          hosts:
            line-c-ws-[001:050]:
              ansible_host: 192.168.103.[10:59]
              node_role: agent
              production_line: C
              zone: testing
              
        line_d:
          hosts:
            line-d-ws-[001:050]:
              ansible_host: 192.168.104.[10:59]
              node_role: agent
              production_line: D
              zone: packaging
              
    offline_registry:
      hosts:
        registry-01:
          ansible_host: 192.168.100.20
          registry_role: primary
        registry-02:
          ansible_host: 192.168.100.21
          registry_role: secondary
EOF
```

### 1.3 Pre-deployment Validation

Verify connectivity and requirements:

```bash
# Test SSH connectivity to all nodes
ansible all -i ansible/inventory.yml -m ping

# Check system requirements
ansible all -i ansible/inventory.yml -m setup -a "filter=ansible_memtotal_mb,ansible_processor_vcpus,ansible_mounts"

# Verify OS versions
ansible all -i ansible/inventory.yml -m shell -a "cat /etc/os-release"
```

## Phase 2: Infrastructure Services Deployment

### 2.1 Container Registry Setup

Deploy the primary container registry:

```bash
# Deploy registry infrastructure
ansible-playbook -i ansible/inventory.yml ansible/site.yml \
  --limit "offline_registry" \
  --tags "container_registry"

# Verify registry deployment
curl -k https://registry-01.factory.local:5000/v2/
```

### 2.2 Helm Chart Repository

Setup local Helm chart mirror:

```bash
# Deploy ChartMuseum
ansible-playbook -i ansible/inventory.yml ansible/site.yml \
  --limit "offline_registry" \
  --tags "helm_mirror"

# Verify chart repository
curl http://registry-01.factory.local:8080/health
```

### 2.3 Image Mirroring

Mirror essential container images:

```bash
# Create image mirror script
cat > scripts/mirror-images.sh << 'EOF'
#!/bin/bash
REGISTRY="registry-01.factory.local:5000"
IMAGES=(
    "rancher/rke2-runtime:v1.28.8-rke2r1"
    "rancher/pause:3.6"
    "rancher/coredns-coredns:1.10.1"
    "rancher/metrics-server:v0.6.3"
    "factory/quality-control:v1.2.3"
    "factory/assembly-monitor:v2.1.0"
    "factory/test-automation:v1.5.2"
    "factory/packaging-automation:v1.3.1"
    "postgres:13-alpine"
    "redis:7-alpine"
    "prometheus/prometheus:v2.45.0"
    "grafana/grafana:10.0.0"
)

for image in "${IMAGES[@]}"; do
    echo "Mirroring $image..."
    docker pull $image
    docker tag $image $REGISTRY/$image
    docker push $REGISTRY/$image
done
EOF

chmod +x scripts/mirror-images.sh
./scripts/mirror-images.sh
```

## Phase 3: RKE2 Cluster Deployment

### 3.1 Master Nodes Deployment

Deploy the Kubernetes control plane:

```bash
# Deploy first master (bootstrap)
ansible-playbook -i ansible/inventory.yml ansible/site.yml \
  --limit "factory-master-01" \
  --tags "os_patching,rke2_install,rke2_master"

# Wait for cluster initialization
sleep 120

# Deploy additional masters
ansible-playbook -i ansible/inventory.yml ansible/site.yml \
  --limit "factory-master-02,factory-master-03" \
  --tags "os_patching,rke2_install,rke2_master"

# Verify cluster status
ssh -i ~/.ssh/factory_rsa admin@192.168.100.10 \
  "sudo /usr/local/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes"
```

### 3.2 Worker Nodes Deployment

Deploy worker nodes by production line:

```bash
# Deploy Line A (Quality Control)
ansible-playbook -i ansible/inventory.yml ansible/site.yml \
  --limit "line_a" \
  --tags "os_patching,rke2_install,rke2_worker" \
  --serial 10

# Deploy Line B (Assembly)
ansible-playbook -i ansible/inventory.yml ansible/site.yml \
  --limit "line_b" \
  --tags "os_patching,rke2_install,rke2_worker" \
  --serial 10

# Deploy Line C (Testing)
ansible-playbook -i ansible/inventory.yml ansible/site.yml \
  --limit "line_c" \
  --tags "os_patching,rke2_install,rke2_worker" \
  --serial 10

# Deploy Line D (Packaging)
ansible-playbook -i ansible/inventory.yml ansible/site.yml \
  --limit "line_d" \
  --tags "os_patching,rke2_install,rke2_worker" \
  --serial 10
```

### 3.3 Cluster Validation

Verify cluster health and readiness:

```bash
# Copy kubeconfig locally
scp -i ~/.ssh/factory_rsa admin@192.168.100.10:/etc/rancher/rke2/rke2.yaml ./kubeconfig
sed -i 's/127.0.0.1/192.168.100.10/g' ./kubeconfig
export KUBECONFIG=./kubeconfig

# Check all nodes
kubectl get nodes -o wide

# Verify node labels
kubectl get nodes --show-labels

# Check system pods
kubectl get pods --all-namespaces
```

## Phase 4: Factory Applications Deployment

### 4.1 Namespace Creation

Create application namespaces:

```bash
kubectl create namespace factory-apps
kubectl create namespace factory-monitoring
kubectl create namespace factory-security

# Label namespaces
kubectl label namespace factory-apps environment=production
kubectl label namespace factory-monitoring environment=production
kubectl label namespace factory-security environment=production
```

### 4.2 Storage Configuration

Setup persistent storage for applications:

```bash
# Create storage class for factory workloads
kubectl apply -f - << 'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: factory-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
EOF
```

### 4.3 Factory Application Deployment

Deploy factory-specific applications:

```bash
# Deploy quality control applications
kubectl apply -f apps/quality-control-dashboard.yaml

# Deploy metrics storage
kubectl apply -f apps/factory-metrics-storage.yaml

# Deploy monitoring stack
ansible-playbook -i ansible/inventory.yml ansible/site.yml \
  --limit "masters[0]" \
  --tags "monitoring_stack"

# Verify application deployment
kubectl get pods -n factory-apps -o wide
kubectl get services -n factory-apps
```

## Phase 5: Anthos Config Management Setup

### 5.1 Service Account Setup

Create Google Cloud service account:

```bash
# Create service account (run on connected machine)
gcloud iam service-accounts create factory-anthos \
  --display-name="Factory Anthos Config Management"

# Grant necessary permissions
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:factory-anthos@PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/anthosconfigmanagement.configSyncAdmin"

# Download service account key
gcloud iam service-accounts keys create ~/factory-anthos-sa-key.json \
  --iam-account=factory-anthos@PROJECT_ID.iam.gserviceaccount.com
```

### 5.2 Git Repository Setup

Create configuration repository:

```bash
# Create Git repository structure
mkdir factory-k8s-config
cd factory-k8s-config

# Initialize repository structure
mkdir -p {namespaces,cluster,policies,apps}

# Create cluster configuration
cat > cluster/cluster-config.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: factory-cluster-config
  namespace: kube-system
data:
  cluster.name: "factory-floor-k8s"
  cluster.environment: "production"
  cluster.location: "factory-floor"
EOF

# Create namespace configurations
cat > namespaces/factory-apps.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: factory-apps
  labels:
    environment: production
    managed-by: anthos-config-sync
EOF

# Initialize Git repository
git init
git add .
git commit -m "Initial factory configuration"
git remote add origin https://github.com/company/factory-k8s-config.git
git push -u origin main
```

### 5.3 Config Management Deployment

Deploy Anthos Config Management:

```bash
# Install Config Management operator
kubectl apply -f https://github.com/GoogleCloudPlatform/anthos-config-management/releases/download/1.15.1/config-management-operator.yaml

# Create service account secret
kubectl create secret generic git-creds \
  --namespace=config-management-system \
  --from-file=ssh=/home/admin/.ssh/factory_git_key

# Deploy ConfigManagement resource
kubectl apply -f anthos-config/config-management.yaml

# Monitor deployment
kubectl get configmanagement -n config-management-system -o yaml
```

## Phase 6: Monitoring and Observability

### 6.1 Prometheus Deployment

Deploy monitoring infrastructure:

```bash
# Create monitoring namespace
kubectl create namespace monitoring

# Deploy Prometheus
kubectl apply -f - << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      nodeSelector:
        node-role.kubernetes.io/master: "true"
      containers:
      - name: prometheus
        image: registry-01.factory.local:5000/prometheus/prometheus:v2.45.0
        ports:
        - containerPort: 9090
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
        - name: storage
          mountPath: /prometheus
      volumes:
      - name: config
        configMap:
          name: prometheus-config
      - name: storage
        persistentVolumeClaim:
          claimName: prometheus-storage
EOF
```

### 6.2 Grafana Deployment

Deploy visualization dashboard:

```bash
# Deploy Grafana
kubectl apply -f - << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      nodeSelector:
        node-role.kubernetes.io/master: "true"
      containers:
      - name: grafana
        image: registry-01.factory.local:5000/grafana/grafana:10.0.0
        ports:
        - containerPort: 3000
        env:
        - name: GF_SECURITY_ADMIN_PASSWORD
          value: "factory_admin_password"
        volumeMounts:
        - name: storage
          mountPath: /var/lib/grafana
      volumes:
      - name: storage
        persistentVolumeClaim:
          claimName: grafana-storage
EOF
```

## Phase 7: Security Hardening

### 7.1 RBAC Configuration

Deploy role-based access control:

```bash
# Create factory operator role
kubectl apply -f - << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: factory-operator
rules:
- apiGroups: [""]
  resources: ["nodes", "pods", "services", "endpoints"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "daemonsets", "replicasets"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["nodes", "pods"]
  verbs: ["get", "list"]
EOF

# Create service account
kubectl create serviceaccount factory-operator -n factory-apps

# Bind role to service account
kubectl create clusterrolebinding factory-operator-binding \
  --clusterrole=factory-operator \
  --serviceaccount=factory-apps:factory-operator
```

### 7.2 Network Policies

Implement network segmentation:

```bash
# Create production line isolation policy
kubectl apply -f - << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: production-line-isolation
  namespace: factory-apps
spec:
  podSelector:
    matchLabels:
      production-line: A
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          production-line: A
    - namespaceSelector:
        matchLabels:
          name: kube-system
  egress:
  - to:
    - podSelector:
        matchLabels:
          production-line: A
    - namespaceSelector:
        matchLabels:
          name: kube-system
  - to: []
    ports:
    - protocol: TCP
      port: 53
    - protocol: UDP
      port: 53
EOF
```

## Phase 8: Backup and Disaster Recovery

### 8.1 etcd Backup Configuration

Setup automated backups:

```bash
# Create backup script on master nodes
ansible masters -i ansible/inventory.yml -m copy -a "
content='#!/bin/bash
BACKUP_DIR=\"/opt/etcd-backups\"
TIMESTAMP=\$(date +%Y%m%d-%H%M%S)
mkdir -p \$BACKUP_DIR
/usr/local/bin/rke2 etcd-snapshot save --name factory-backup-\$TIMESTAMP
find \$BACKUP_DIR -name \"*.db\" -mtime +7 -delete
' dest=/opt/backup-etcd.sh mode=0755"

# Setup cron job for daily backups
ansible masters -i ansible/inventory.yml -m cron -a "
name='etcd backup'
minute='0'
hour='2'
job='/opt/backup-etcd.sh'
user=root"
```

### 8.2 Application Data Backup

Configure application data backups:

```bash
# Create database backup job
kubectl apply -f - << 'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup
  namespace: factory-monitoring
spec:
  schedule: "0 3 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: postgres-backup
            image: registry-01.factory.local:5000/postgres:13-alpine
            command:
            - /bin/bash
            - -c
            - |
              TIMESTAMP=$(date +%Y%m%d-%H%M%S)
              pg_dump -h postgres-service -U metrics_user factory_metrics > /backup/factory-db-$TIMESTAMP.sql
              find /backup -name "*.sql" -mtime +30 -delete
            env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-secret
                  key: password
            volumeMounts:
            - name: backup-storage
              mountPath: /backup
          volumes:
          - name: backup-storage
            persistentVolumeClaim:
              claimName: backup-storage
          restartPolicy: OnFailure
EOF
```

## Phase 9: Validation and Testing

### 9.1 Cluster Health Validation

Perform comprehensive cluster validation:

```bash
# Run cluster health checks
./scripts/validate-cluster.sh

# Expected output:
# ✓ All nodes ready
# ✓ All system pods running
# ✓ etcd cluster healthy
# ✓ API server responding
# ✓ DNS resolution working
# ✓ Network connectivity verified
```

### 9.2 Application Testing

Test factory applications:

```bash
# Test quality control application
kubectl exec -n factory-apps -l app=quality-control -- /app/test-scan.sh

# Test assembly monitor
kubectl exec -n factory-apps -l app=assembly-monitor -- /app/test-metrics.sh

# Test automation systems
kubectl exec -n factory-apps -l app=test-automation -- /app/test-equipment.sh

# Test packaging system
kubectl exec -n factory-apps -l app=packaging-automation -- /app/test-printer.sh
```

### 9.3 Performance Validation

Validate system performance:

```bash
# Check resource utilization
kubectl top nodes
kubectl top pods --all-namespaces

# Run performance tests
kubectl apply -f - << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: performance-test
spec:
  template:
    spec:
      containers:
      - name: stress-test
        image: registry-01.factory.local:5000/busybox
        command: ['sh', '-c', 'stress --cpu 2 --timeout 60s']
      restartPolicy: Never
EOF
```

## Phase 10: Documentation and Handover

### 10.1 Operational Documentation

Create operational runbooks:

```bash
# Generate cluster information
kubectl cluster-info > docs/cluster-info.txt
kubectl get nodes -o wide > docs/node-inventory.txt
kubectl get pods --all-namespaces -o wide > docs/pod-inventory.txt

# Create access credentials
kubectl config view --raw > docs/admin-kubeconfig.yaml
kubectl get secrets --all-namespaces > docs/secrets-inventory.txt
```

### 10.2 Training Materials

Prepare training documentation:

- **Operator Guide**: Daily operations and monitoring procedures
- **Troubleshooting Guide**: Common issues and resolution steps  
- **Maintenance Guide**: Scheduled maintenance procedures
- **Emergency Procedures**: Disaster recovery and incident response

### 10.3 Monitoring Setup

Configure alerting and notifications:

```bash
# Create alert rules for factory operations
kubectl apply -f monitoring/factory-alerts.yaml

# Setup Slack integration
kubectl create secret generic alertmanager-slack \
  --from-literal=webhook-url=https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK

# Configure email notifications
kubectl apply -f monitoring/email-config.yaml
```

## Deployment Verification Checklist

### ✅ Infrastructure
- [ ] All 203 nodes (3 masters + 200 workers) are healthy and ready
- [ ] Container registry accessible from all nodes
- [ ] Helm chart repository serving charts
- [ ] Network connectivity verified between all components

### ✅ Applications
- [ ] Quality control applications running on Line A workstations
- [ ] Assembly monitoring active on Line B workstations
- [ ] Test automation deployed on Line C workstations
- [ ] Packaging automation operational on Line D workstations

### ✅ Security
- [ ] RBAC policies implemented and tested
- [ ] Network policies isolating production lines
- [ ] Certificate management operational
- [ ] Audit logging enabled and functioning

### ✅ Operations
- [ ] Monitoring and alerting configured
- [ ] Backup procedures validated
- [ ] GitOps pipeline operational
- [ ] Maintenance procedures documented

### ✅ Documentation
- [ ] Operational runbooks created
- [ ] Emergency procedures documented
- [ ] Training materials prepared
- [ ] Access credentials secured

## Next Steps

After successful deployment:

1. **Schedule Training**: Train operations team on daily procedures
2. **Establish Monitoring**: Set up 24/7 monitoring dashboard
3. **Plan Maintenance**: Schedule first maintenance window
4. **Performance Optimization**: Monitor and tune based on actual workloads
5. **Capacity Planning**: Plan for future expansion and scaling

The factory floor Kubernetes cluster is now ready for production operations!
