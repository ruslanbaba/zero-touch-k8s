# Factory Infrastructure Monitoring Stack

## Overview
This Helm chart deploys the complete monitoring infrastructure for the factory floor Kubernetes environment, including Prometheus, Grafana, AlertManager, and factory-specific dashboards.

## Installation

### Prerequisites
- Kubernetes cluster with factory-apps namespace
- Persistent storage class configured
- Factory registry accessible

### Install the monitoring stack
```bash
helm install factory-monitoring ./factory-monitoring \
  --namespace factory-monitoring \
  --create-namespace \
  --values values-production.yaml
```

### Upgrade existing installation
```bash
helm upgrade factory-monitoring ./factory-monitoring \
  --namespace factory-monitoring \
  --values values-production.yaml
```

## Configuration

### Prometheus Configuration
- Retention: 30 days
- Storage: 50GB persistent volume
- Scrape interval: 15 seconds
- Evaluation interval: 15 seconds

### Grafana Configuration
- Admin password: Set via values.yaml
- Persistent storage: 10GB
- Factory-specific dashboards included
- LDAP authentication supported

### AlertManager Configuration
- Slack integration for critical alerts
- Email notifications for warnings
- PagerDuty integration for production issues

## Factory-Specific Metrics

### Production Line Metrics
- Quality control defect rates
- Assembly line throughput
- Test automation success rates
- Packaging efficiency metrics

### Infrastructure Metrics
- Node resource utilization
- Pod performance metrics
- Network latency and throughput
- Storage I/O performance

## Dashboards

### Factory Overview Dashboard
- Overall production metrics
- Quality control summary
- Resource utilization
- Alert status

### Production Line Dashboards
- Line A: Quality Control Dashboard
- Line B: Assembly Line Dashboard
- Line C: Testing Dashboard
- Line D: Packaging Dashboard

### Infrastructure Dashboard
- Kubernetes cluster health
- Node performance
- Storage utilization
- Network performance

## Alerting Rules

### Critical Alerts
- Production line down
- High defect rate
- Equipment failure
- Security incidents

### Warning Alerts
- High resource utilization
- Slow response times
- Certificate expiration
- Backup failures

## Troubleshooting

### Common Issues
1. **Prometheus not scraping targets**
   - Check network policies
   - Verify service discovery
   - Check RBAC permissions

2. **Grafana dashboards not loading**
   - Verify data source configuration
   - Check Prometheus connectivity
   - Review dashboard JSON syntax

3. **Alerts not firing**
   - Check alert rule syntax
   - Verify AlertManager configuration
   - Test notification channels

### Useful Commands
```bash
# Check Prometheus targets
kubectl port-forward -n factory-monitoring svc/prometheus 9090:9090

# Access Grafana
kubectl port-forward -n factory-monitoring svc/grafana 3000:3000

# View AlertManager configuration
kubectl get secret -n factory-monitoring alertmanager-config -o yaml
```
