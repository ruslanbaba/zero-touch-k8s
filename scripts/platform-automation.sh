#!/bin/bash
# Platform Engineering automation for enhanced developer experience

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_NAMESPACE="platform-system"
TEMPLATES_DIR="${SCRIPT_DIR}/../platform/templates"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
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

# Initialize platform capabilities
init_platform() {
    info "Initializing Factory Platform Engineering capabilities..."
    
    # Create platform namespace
    kubectl create namespace $PLATFORM_NAMESPACE || true
    
    # Install Crossplane for infrastructure provisioning
    install_crossplane
    
    # Install Argo Workflows for pipeline automation
    install_argo_workflows
    
    # Install Tekton for CI/CD pipelines
    install_tekton
    
    # Setup developer onboarding automation
    setup_developer_onboarding
    
    success "Platform initialization completed"
}

# Install Crossplane for Infrastructure as Code
install_crossplane() {
    info "Installing Crossplane for infrastructure provisioning..."
    
    helm repo add crossplane-stable https://charts.crossplane.io/stable
    helm repo update
    
    helm install crossplane crossplane-stable/crossplane \
        --namespace crossplane-system \
        --create-namespace \
        --wait
    
    # Install factory-specific providers
    kubectl apply -f - <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-kubernetes
spec:
  package: crossplane/provider-kubernetes:v0.6.0
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-helm
spec:
  package: crossplane/provider-helm:v0.13.0
---
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: factory-platform-config
spec:
  package: factory-registry.local:5000/crossplane-config:v1.0.0
EOF

    success "Crossplane installation completed"
}

# Install Argo Workflows
install_argo_workflows() {
    info "Installing Argo Workflows for automation..."
    
    kubectl create namespace argo || true
    kubectl apply -n argo -f https://github.com/argoproj/argo-workflows/releases/download/v3.4.0/install.yaml
    
    # Configure workflow templates
    kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: factory-app-deployment
  namespace: argo
spec:
  entrypoint: deploy-factory-app
  templates:
  - name: deploy-factory-app
    inputs:
      parameters:
      - name: app-name
      - name: production-line
      - name: image-tag
    script:
      image: factory-registry.local:5000/deployment-tools:latest
      command: [bash]
      source: |
        #!/bin/bash
        set -e
        
        APP_NAME="{{inputs.parameters.app-name}}"
        PRODUCTION_LINE="{{inputs.parameters.production-line}}"
        IMAGE_TAG="{{inputs.parameters.image-tag}}"
        
        echo "Deploying \$APP_NAME to production line \$PRODUCTION_LINE..."
        
        # Generate application manifest
        envsubst < /templates/factory-app.yaml | kubectl apply -f -
        
        # Wait for deployment
        kubectl rollout status deployment/\$APP_NAME -n factory-line-\${PRODUCTION_LINE,,}
        
        echo "Deployment completed successfully"
EOF

    success "Argo Workflows installation completed"
}

# Install Tekton for CI/CD
install_tekton() {
    info "Installing Tekton for CI/CD pipelines..."
    
    kubectl apply --filename https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
    kubectl apply --filename https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
    kubectl apply --filename https://storage.googleapis.com/tekton-releases/dashboard/latest/tekton-dashboard-release.yaml
    
    # Create factory-specific pipeline tasks
    kubectl apply -f - <<EOF
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: factory-security-scan
  namespace: tekton-pipelines
spec:
  params:
  - name: image
    description: Reference of the image to scan
  steps:
  - name: scan
    image: aquasec/trivy:latest
    script: |
      #!/bin/sh
      trivy image --exit-code 1 --severity HIGH,CRITICAL \$(params.image)
---
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: factory-deployment
  namespace: tekton-pipelines
spec:
  params:
  - name: app-name
  - name: production-line
  - name: image
  steps:
  - name: deploy
    image: factory-registry.local:5000/kubectl:latest
    script: |
      #!/bin/bash
      kubectl set image deployment/\$(params.app-name) \
        app=\$(params.image) \
        -n factory-line-\$(echo \$(params.production-line) | tr '[:upper:]' '[:lower:]')
EOF

    success "Tekton installation completed"
}

# Setup developer onboarding automation
setup_developer_onboarding() {
    info "Setting up developer onboarding automation..."
    
    # Create onboarding workflow
    kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: developer-onboarding
  namespace: argo
spec:
  entrypoint: onboard-developer
  templates:
  - name: onboard-developer
    inputs:
      parameters:
      - name: developer-name
      - name: team
      - name: access-level
    dag:
      tasks:
      - name: create-namespace
        template: create-dev-namespace
        arguments:
          parameters:
          - name: developer-name
            value: "{{inputs.parameters.developer-name}}"
      
      - name: setup-rbac
        template: setup-developer-rbac
        arguments:
          parameters:
          - name: developer-name
            value: "{{inputs.parameters.developer-name}}"
          - name: team
            value: "{{inputs.parameters.team}}"
          - name: access-level
            value: "{{inputs.parameters.access-level}}"
        depends: "create-namespace"
      
      - name: create-dev-environment
        template: create-development-environment
        arguments:
          parameters:
          - name: developer-name
            value: "{{inputs.parameters.developer-name}}"
        depends: "setup-rbac"
      
      - name: send-welcome-email
        template: send-notification
        arguments:
          parameters:
          - name: developer-name
            value: "{{inputs.parameters.developer-name}}"
        depends: "create-dev-environment"
  
  - name: create-dev-namespace
    inputs:
      parameters:
      - name: developer-name
    script:
      image: factory-registry.local:5000/kubectl:latest
      command: [bash]
      source: |
        DEV_NAME="{{inputs.parameters.developer-name}}"
        NAMESPACE="dev-\${DEV_NAME,,}"
        
        kubectl create namespace "\$NAMESPACE" || true
        kubectl label namespace "\$NAMESPACE" team=development type=personal
  
  - name: setup-developer-rbac
    inputs:
      parameters:
      - name: developer-name
      - name: team
      - name: access-level
    script:
      image: factory-registry.local:5000/kubectl:latest
      command: [bash]
      source: |
        DEV_NAME="{{inputs.parameters.developer-name}}"
        TEAM="{{inputs.parameters.team}}"
        ACCESS_LEVEL="{{inputs.parameters.access-level}}"
        NAMESPACE="dev-\${DEV_NAME,,}"
        
        # Create ServiceAccount
        kubectl create serviceaccount "\$DEV_NAME" -n "\$NAMESPACE"
        
        # Create appropriate Role based on access level
        case \$ACCESS_LEVEL in
          "full")
            kubectl create rolebinding "\$DEV_NAME-admin" \
              --clusterrole=admin \
              --serviceaccount="\$NAMESPACE:\$DEV_NAME" \
              -n "\$NAMESPACE"
            ;;
          "limited")
            kubectl create rolebinding "\$DEV_NAME-edit" \
              --clusterrole=edit \
              --serviceaccount="\$NAMESPACE:\$DEV_NAME" \
              -n "\$NAMESPACE"
            ;;
          "readonly")
            kubectl create rolebinding "\$DEV_NAME-view" \
              --clusterrole=view \
              --serviceaccount="\$NAMESPACE:\$DEV_NAME" \
              -n "\$NAMESPACE"
            ;;
        esac
  
  - name: create-development-environment
    inputs:
      parameters:
      - name: developer-name
    script:
      image: factory-registry.local:5000/helm:latest
      command: [bash]
      source: |
        DEV_NAME="{{inputs.parameters.developer-name}}"
        NAMESPACE="dev-\${DEV_NAME,,}"
        
        # Install development tools
        helm install "\$DEV_NAME-tools" factory-charts/dev-environment \
          --namespace "\$NAMESPACE" \
          --set developer.name="\$DEV_NAME" \
          --set resources.requests.cpu="500m" \
          --set resources.requests.memory="1Gi"
  
  - name: send-notification
    inputs:
      parameters:
      - name: developer-name
    script:
      image: curlimages/curl:latest
      command: [sh]
      source: |
        DEV_NAME="{{inputs.parameters.developer-name}}"
        
        curl -X POST "\$SLACK_WEBHOOK_URL" \
          -H 'Content-type: application/json' \
          --data "{
            \"text\": \"🎉 Developer onboarding completed for \$DEV_NAME! Welcome to the Factory Platform team!\",
            \"channel\": \"#platform-team\"
          }"
EOF

    success "Developer onboarding automation setup completed"
}

# Create application from template
create_app_from_template() {
    local app_name=$1
    local production_line=$2
    local template_type=${3:-basic}
    local developer=${4:-$(whoami)}
    
    info "Creating application '$app_name' for production line '$production_line' using template '$template_type'..."
    
    local namespace="factory-line-${production_line,,}"
    
    # Ensure namespace exists
    kubectl create namespace "$namespace" || true
    
    # Create application from template
    case $template_type in
        "basic")
            create_basic_factory_app "$app_name" "$production_line" "$developer"
            ;;
        "monitoring")
            create_monitoring_app "$app_name" "$production_line" "$developer"
            ;;
        "data-processing")
            create_data_processing_app "$app_name" "$production_line" "$developer"
            ;;
        *)
            error "Unknown template type: $template_type"
            ;;
    esac
    
    success "Application '$app_name' created successfully"
}

# Create basic factory application
create_basic_factory_app() {
    local app_name=$1
    local production_line=$2
    local developer=$3
    local namespace="factory-line-${production_line,,}"
    
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $app_name
  namespace: $namespace
  labels:
    app: $app_name
    production-line: "$production_line"
    created-by: "$developer"
    template: "basic-factory-app"
spec:
  replicas: 3
  selector:
    matchLabels:
      app: $app_name
  template:
    metadata:
      labels:
        app: $app_name
        production-line: "$production_line"
    spec:
      containers:
      - name: app
        image: factory-registry.local:5000/factory-app-template:latest
        ports:
        - containerPort: 8080
        env:
        - name: PRODUCTION_LINE
          value: "$production_line"
        - name: APP_NAME
          value: "$app_name"
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: $app_name
  namespace: $namespace
  labels:
    app: $app_name
spec:
  selector:
    app: $app_name
  ports:
  - port: 80
    targetPort: 8080
  type: ClusterIP
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: $app_name
  namespace: $namespace
  labels:
    app: $app_name
spec:
  selector:
    matchLabels:
      app: $app_name
  endpoints:
  - port: http
    interval: 30s
    path: /metrics
EOF
}

# Provision development environment
provision_dev_environment() {
    local developer=$1
    local duration=${2:-4h}
    local size=${3:-medium}
    
    info "Provisioning development environment for $developer (duration: $duration, size: $size)..."
    
    local namespace="dev-${developer,,}"
    local expiry_time=$(date -d "+$duration" +%s)
    
    # Create temporary namespace with expiry
    kubectl create namespace "$namespace" || true
    kubectl annotate namespace "$namespace" \
        expiry="$expiry_time" \
        size="$size" \
        owner="$developer"
    
    # Install development tools based on size
    local cpu_request="500m"
    local memory_request="1Gi"
    local cpu_limit="1"
    local memory_limit="2Gi"
    
    case $size in
        "small")
            cpu_request="250m"
            memory_request="512Mi"
            cpu_limit="500m"
            memory_limit="1Gi"
            ;;
        "large")
            cpu_request="1"
            memory_request="2Gi"
            cpu_limit="2"
            memory_limit="4Gi"
            ;;
    esac
    
    # Deploy development environment
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dev-environment
  namespace: $namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dev-environment
  template:
    metadata:
      labels:
        app: dev-environment
    spec:
      containers:
      - name: vscode-server
        image: factory-registry.local:5000/vscode-server:latest
        ports:
        - containerPort: 8080
        env:
        - name: DEVELOPER
          value: "$developer"
        resources:
          requests:
            cpu: $cpu_request
            memory: $memory_request
          limits:
            cpu: $cpu_limit
            memory: $memory_limit
        volumeMounts:
        - name: workspace
          mountPath: /workspace
      volumes:
      - name: workspace
        persistentVolumeClaim:
          claimName: dev-workspace
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dev-workspace
  namespace: $namespace
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: dev-environment
  namespace: $namespace
spec:
  selector:
    app: dev-environment
  ports:
  - port: 80
    targetPort: 8080
  type: LoadBalancer
EOF

    # Schedule cleanup
    schedule_environment_cleanup "$namespace" "$expiry_time"
    
    success "Development environment provisioned for $developer"
    info "Environment will be automatically cleaned up at $(date -d "@$expiry_time")"
}

# Schedule environment cleanup
schedule_environment_cleanup() {
    local namespace=$1
    local expiry_time=$2
    
    kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: cleanup-${namespace}
  namespace: default
spec:
  schedule: "$(date -d "@$expiry_time" +"%M %H %d %m *")"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: cleanup
            image: factory-registry.local:5000/kubectl:latest
            command:
            - /bin/bash
            - -c
            - |
              echo "Cleaning up development environment: $namespace"
              kubectl delete namespace $namespace
              kubectl delete job cleanup-$namespace
          restartPolicy: Never
EOF
}

# Generate platform metrics
generate_platform_metrics() {
    info "Generating platform metrics and usage statistics..."
    
    local metrics_file="/tmp/platform-metrics-$(date +%Y%m%d).json"
    
    # Collect platform usage metrics
    cat > "$metrics_file" <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "platform_stats": {
    "total_applications": $(kubectl get deployments --all-namespaces --no-headers | wc -l),
    "total_namespaces": $(kubectl get namespaces --no-headers | wc -l),
    "active_developers": $(kubectl get namespaces -l team=development --no-headers | wc -l),
    "resource_utilization": {
      "cpu_usage": "$(kubectl top nodes --no-headers | awk '{sum += $3} END {print sum "%"}' | sed 's/%$//')",
      "memory_usage": "$(kubectl top nodes --no-headers | awk '{sum += $5} END {print sum "%"}' | sed 's/%$//')"
    },
    "production_lines": {
      "line_a_apps": $(kubectl get deployments -n factory-line-a --no-headers | wc -l),
      "line_b_apps": $(kubectl get deployments -n factory-line-b --no-headers | wc -l),
      "line_c_apps": $(kubectl get deployments -n factory-line-c --no-headers | wc -l),
      "line_d_apps": $(kubectl get deployments -n factory-line-d --no-headers | wc -l)
    },
    "cost_metrics": {
      "estimated_monthly_cost": "\$$(echo "scale=2; $(kubectl get nodes --no-headers | wc -l) * 100" | bc)",
      "cost_per_application": "\$$(echo "scale=2; $(kubectl get nodes --no-headers | wc -l) * 100 / $(kubectl get deployments --all-namespaces --no-headers | wc -l)" | bc)"
    }
  }
}
EOF
    
    success "Platform metrics generated: $metrics_file"
    cat "$metrics_file"
}

# Show usage
usage() {
    echo "Usage: $0 {init|create-app|provision-dev|cleanup|metrics} [options]"
    echo ""
    echo "Commands:"
    echo "  init                                    - Initialize platform capabilities"
    echo "  create-app <name> <line> [template]     - Create application from template"
    echo "  provision-dev <developer> [duration]    - Provision development environment"
    echo "  onboard <developer> <team> <access>     - Onboard new developer"
    echo "  cleanup                                 - Clean up expired environments"
    echo "  metrics                                 - Generate platform metrics"
    echo ""
    echo "Examples:"
    echo "  $0 init"
    echo "  $0 create-app my-app A basic"
    echo "  $0 provision-dev john 8h medium"
    echo "  $0 onboard jane platform-team full"
    echo "  $0 metrics"
    exit 1
}

# Main function
main() {
    local command=${1:-}
    
    case $command in
        init)
            init_platform
            ;;
        create-app)
            create_app_from_template "$2" "$3" "${4:-basic}" "${5:-$(whoami)}"
            ;;
        provision-dev)
            provision_dev_environment "$2" "${3:-4h}" "${4:-medium}"
            ;;
        onboard)
            onboard_developer "$2" "$3" "$4"
            ;;
        cleanup)
            cleanup_expired_environments
            ;;
        metrics)
            generate_platform_metrics
            ;;
        *)
            usage
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
