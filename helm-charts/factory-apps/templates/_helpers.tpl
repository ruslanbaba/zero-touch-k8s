{{/*
Expand the name of the chart.
*/}}
{{- define "factory-apps.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "factory-apps.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "factory-apps.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "factory-apps.labels" -}}
helm.sh/chart: {{ include "factory-apps.chart" . }}
{{ include "factory-apps.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
environment: {{ .Values.labels.environment }}
location: {{ .Values.labels.location }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "factory-apps.selectorLabels" -}}
app.kubernetes.io/name: {{ include "factory-apps.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "factory-apps.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "factory-apps.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Factory registry image pull secret
*/}}
{{- define "factory-apps.imagePullSecrets" -}}
{{- if .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.global.imagePullSecrets }}
- name: {{ . }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Factory tolerations for workstation nodes
*/}}
{{- define "factory-apps.tolerations" -}}
tolerations:
- key: "factory-floor"
  operator: "Equal"
  value: "true"
  effect: "NoSchedule"
{{- end }}

{{/*
Production line node selector
*/}}
{{- define "factory-apps.nodeSelector" -}}
{{- if .productionLine }}
nodeSelector:
  production-line: {{ .productionLine | quote }}
  zone: {{ .zone | quote }}
{{- end }}
{{- end }}
