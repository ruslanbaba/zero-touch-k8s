# Deployment Architecture

This document provides detailed technical architecture information for the Zero-Touch Factory Floor Kubernetes deployment.

## Network Architecture

### Network Segmentation

The factory floor network is segmented into isolated VLANs for security and performance:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Factory Network                              │
├─────────────────────────────────────────────────────────────────────┤
│ Management VLAN (192.168.100.0/24)                                 │
│ ├── Master Nodes (.10-.12)                                         │
│ ├── Infrastructure Services (.20-.30)                              │
│ └── Network Management (.1-.9)                                     │
├─────────────────────────────────────────────────────────────────────┤
│ Production VLAN A (192.168.101.0/24) - Quality Control            │
│ └── Workstations (.10-.59)                                         │
├─────────────────────────────────────────────────────────────────────┤
│ Production VLAN B (192.168.102.0/24) - Assembly                   │
│ └── Workstations (.10-.59)                                         │
├─────────────────────────────────────────────────────────────────────┤
│ Production VLAN C (192.168.103.0/24) - Testing                    │
│ └── Workstations (.10-.59)                                         │
├─────────────────────────────────────────────────────────────────────┤
│ Production VLAN D (192.168.104.0/24) - Packaging                  │
│ └── Workstations (.10-.59)                                         │
└─────────────────────────────────────────────────────────────────────┘
```

## Component Architecture

### Control Plane Components

#### Master Nodes (High Availability)
- **3 Master Nodes** for etcd quorum and API server redundancy
- **Load Balancer** distributes API requests across masters
- **etcd Cluster** stores cluster state with automatic backups

```mermaid
graph TB
    subgraph "Master Node Architecture"
        subgraph "Master 1 (192.168.100.10)"
            M1_API[kube-apiserver]
            M1_SCHED[kube-scheduler]
            M1_CM[kube-controller-manager]
            M1_ETCD[etcd]
            M1_PROXY[kube-proxy]
        end
        
        subgraph "Master 2 (192.168.100.11)"
            M2_API[kube-apiserver]
            M2_SCHED[kube-scheduler]
            M2_CM[kube-controller-manager]
            M2_ETCD[etcd]
            M2_PROXY[kube-proxy]
        end
        
        subgraph "Master 3 (192.168.100.12)"
            M3_API[kube-apiserver]
            M3_SCHED[kube-scheduler]
            M3_CM[kube-controller-manager]
            M3_ETCD[etcd]
            M3_PROXY[kube-proxy]
        end
        
        M1_ETCD -.->|raft consensus| M2_ETCD
        M2_ETCD -.->|raft consensus| M3_ETCD
        M3_ETCD -.->|raft consensus| M1_ETCD
    end
```

### Infrastructure Services

#### Container Registry Architecture
```mermaid
graph LR
    subgraph "Registry Infrastructure"
        subgraph "Primary Registry (192.168.100.20)"
            REG1[Docker Registry v2]
            REG1_STORAGE[(Storage Volume)]
            REG1_AUTH[Authentication]
            REG1_TLS[TLS Certificates]
        end
        
        subgraph "Secondary Registry (192.168.100.21)"
            REG2[Docker Registry v2]
            REG2_STORAGE[(Storage Volume)]
            REG2_AUTH[Authentication]
            REG2_TLS[TLS Certificates]
        end
        
        subgraph "Helm Chart Repository"
            CHART[ChartMuseum]
            CHART_STORAGE[(Chart Storage)]
        end
        
        REG1 -.->|sync| REG2
        REG1_STORAGE -.->|replicate| REG2_STORAGE
    end
```

### Application Architecture

#### Factory Application Stack
```mermaid
graph TB
    subgraph "Application Layer"
        subgraph "Quality Control"
            QC_APP[Vision Inspection App]
            QC_DB[(Metrics Database)]
            QC_CAMERA[Camera Interface]
        end
        
        subgraph "Assembly Monitoring"
            ASM_APP[Line Monitor App]
            ASM_PLC[PLC Interface]
            ASM_METRICS[Metrics Collector]
        end
        
        subgraph "Test Automation"
            TEST_APP[Test Controller]
            TEST_EQUIP[Test Equipment Interface]
            TEST_RESULTS[(Test Results DB)]
        end
        
        subgraph "Packaging"
            PKG_APP[Package Controller]
            PKG_PRINTER[Label Printer]
            PKG_SCANNER[Barcode Scanner]
        end
    end
    
    subgraph "Data Layer"
        POSTGRES[(PostgreSQL)]
        REDIS[(Redis Cache)]
        METRICS[(Metrics Storage)]
    end
    
    QC_APP --> POSTGRES
    ASM_APP --> REDIS
    TEST_APP --> POSTGRES
    PKG_APP --> METRICS
```

## Data Flow Architecture

### Real-time Data Processing
```mermaid
sequenceDiagram
    participant WS as Workstation
    participant APP as Factory App
    participant DB as Database
    participant MON as Monitoring
    participant ALERT as Alerting
    
    WS->>APP: Sensor Data
    APP->>APP: Process Data
    APP->>DB: Store Metrics
    APP->>MON: Send Metrics
    MON->>MON: Evaluate Rules
    MON->>ALERT: Trigger Alert
    ALERT->>WS: Notification
```

### Configuration Management Flow
```mermaid
graph LR
    subgraph "GitOps Pipeline"
        GIT[Git Repository]
        ACM[Anthos Config Mgmt]
        K8S[Kubernetes API]
        NODES[Factory Nodes]
        
        GIT -->|webhook| ACM
        ACM -->|sync| K8S
        K8S -->|deploy| NODES
        NODES -->|status| K8S
        K8S -->|report| ACM
        ACM -->|commit| GIT
    end
```

## Security Architecture

### Multi-layer Security Model
```mermaid
graph TB
    subgraph "Security Layers"
        subgraph "Network Security"
            FW[Firewall Rules]
            VLAN[VLAN Isolation]
            VPN[VPN Gateway]
        end
        
        subgraph "Cluster Security"
            RBAC[RBAC Policies]
            PSP[Pod Security Policies]
            NET_POL[Network Policies]
            ADMISSION[Admission Controllers]
        end
        
        subgraph "Application Security"
            TLS[TLS Encryption]
            SECRETS[Secret Management]
            SCAN[Image Scanning]
            RUNTIME[Runtime Security]
        end
        
        subgraph "Data Security"
            ENCRYPT[Data Encryption]
            BACKUP[Backup Encryption]
            AUDIT[Audit Logging]
            COMPLIANCE[Compliance Monitoring]
        end
    end
```

### Certificate Management
```mermaid
graph LR
    subgraph "PKI Infrastructure"
        ROOT_CA[Root CA]
        INTER_CA[Intermediate CA]
        
        subgraph "Kubernetes Certificates"
            API_CERT[API Server Cert]
            ETCD_CERT[etcd Cert]
            KUBELET_CERT[Kubelet Cert]
        end
        
        subgraph "Application Certificates"
            REG_CERT[Registry Cert]
            APP_CERT[Application Cert]
            INGRESS_CERT[Ingress Cert]
        end
        
        ROOT_CA --> INTER_CA
        INTER_CA --> API_CERT
        INTER_CA --> ETCD_CERT
        INTER_CA --> KUBELET_CERT
        INTER_CA --> REG_CERT
        INTER_CA --> APP_CERT
        INTER_CA --> INGRESS_CERT
    end
```

## Scalability Architecture

### Horizontal Scaling Strategy
```mermaid
graph TB
    subgraph "Scaling Dimensions"
        subgraph "Compute Scaling"
            NODES[Add Worker Nodes]
            PODS[Scale Pod Replicas]
            RESOURCES[Adjust Resource Limits]
        end
        
        subgraph "Storage Scaling"
            PV[Persistent Volumes]
            REG_SCALE[Registry Scaling]
            DB_SCALE[Database Scaling]
        end
        
        subgraph "Network Scaling"
            BANDWIDTH[Increase Bandwidth]
            LB[Load Balancer Scaling]
            CDN[Content Distribution]
        end
    end
```

### Performance Optimization
```mermaid
graph LR
    subgraph "Performance Layers"
        subgraph "Node Level"
            CPU_OPT[CPU Optimization]
            MEM_OPT[Memory Optimization]
            DISK_OPT[Disk I/O Optimization]
        end
        
        subgraph "Cluster Level"
            SCHED_OPT[Scheduler Optimization]
            ETCD_OPT[etcd Performance]
            NET_OPT[Network Optimization]
        end
        
        subgraph "Application Level"
            IMAGE_OPT[Image Optimization]
            CACHE_OPT[Caching Strategy]
            DB_OPT[Database Optimization]
        end
    end
```

## Disaster Recovery Architecture

### Backup Strategy
```mermaid
graph TB
    subgraph "Backup Components"
        subgraph "Cluster Backup"
            ETCD_BACKUP[etcd Snapshots]
            CONFIG_BACKUP[Configuration Backup]
            CERT_BACKUP[Certificate Backup]
        end
        
        subgraph "Data Backup"
            DB_BACKUP[Database Backup]
            APP_BACKUP[Application Data]
            LOG_BACKUP[Log Archival]
        end
        
        subgraph "Image Backup"
            REG_BACKUP[Registry Backup]
            CHART_BACKUP[Helm Chart Backup]
            ARTIFACT_BACKUP[Build Artifacts]
        end
        
        subgraph "Storage"
            LOCAL_STORAGE[(Local Storage)]
            REMOTE_STORAGE[(Remote Storage)]
            TAPE_STORAGE[(Tape Backup)]
        end
        
        ETCD_BACKUP --> LOCAL_STORAGE
        DB_BACKUP --> LOCAL_STORAGE
        REG_BACKUP --> LOCAL_STORAGE
        LOCAL_STORAGE --> REMOTE_STORAGE
        REMOTE_STORAGE --> TAPE_STORAGE
    end
```

### Recovery Procedures
```mermaid
sequenceDiagram
    participant OPS as Operations Team
    participant BACKUP as Backup System
    participant CLUSTER as Kubernetes Cluster
    participant APPS as Applications
    participant VERIFY as Verification
    
    OPS->>BACKUP: Initiate Recovery
    BACKUP->>CLUSTER: Restore etcd
    CLUSTER->>CLUSTER: Restart Control Plane
    CLUSTER->>APPS: Restore Applications
    APPS->>VERIFY: Health Checks
    VERIFY->>OPS: Recovery Complete
```

## Monitoring Architecture

### Observability Stack
```mermaid
graph TB
    subgraph "Monitoring Infrastructure"
        subgraph "Metrics Collection"
            PROMETHEUS[Prometheus]
            NODE_EXP[Node Exporter]
            KUBE_METRICS[kube-state-metrics]
            APP_METRICS[Application Metrics]
        end
        
        subgraph "Visualization"
            GRAFANA[Grafana]
            FACTORY_DASH[Factory Dashboards]
            ALERT_DASH[Alert Dashboards]
        end
        
        subgraph "Alerting"
            ALERT_MGR[Alertmanager]
            SLACK[Slack Integration]
            EMAIL[Email Alerts]
            WEBHOOK[Webhook Notifications]
        end
        
        subgraph "Logging"
            FLUENTD[Fluentd]
            ELASTICSEARCH[Elasticsearch]
            KIBANA[Kibana]
        end
        
        NODE_EXP --> PROMETHEUS
        KUBE_METRICS --> PROMETHEUS
        APP_METRICS --> PROMETHEUS
        PROMETHEUS --> GRAFANA
        PROMETHEUS --> ALERT_MGR
        ALERT_MGR --> SLACK
        ALERT_MGR --> EMAIL
        
        FLUENTD --> ELASTICSEARCH
        ELASTICSEARCH --> KIBANA
    end
```

This architecture provides a robust, scalable, and secure foundation for factory floor Kubernetes operations with comprehensive monitoring, backup, and disaster recovery capabilities.
