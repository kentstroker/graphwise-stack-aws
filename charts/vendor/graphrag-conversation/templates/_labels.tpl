{{/*
Expand the name of the chart.
*/}}
{{- define "graphrag-conversation.name" -}}
  {{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "graphrag-conversation.fullname" -}}
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
{{- define "graphrag-conversation.chart" -}}
  {{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "graphrag-conversation.labels" -}}
helm.sh/chart: {{ include "graphrag-conversation.chart" . }}
{{ include "graphrag-conversation.selectorLabels" . }}
app.kubernetes.io/version: {{ coalesce .Values.image.tag .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: graphrag-conversation
app.kubernetes.io/part-of: graphrag
{{- if .Values.labels -}}
  {{- tpl (toYaml .Values.labels) . | nindent 0 -}}
{{- end -}}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "graphrag-conversation.selectorLabels" -}}
app.kubernetes.io/name: {{ include "graphrag-conversation.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "graphrag-conversation.serviceAccountName" -}}
  {{- if .Values.serviceAccount.create }}
    {{- default (include "graphrag-conversation.fullname" .) .Values.serviceAccount.name }}
  {{- else }}
    {{- default "default" .Values.serviceAccount.name }}
  {{- end }}
{{- end }}

{{/*
Returns the namespace of the release.
*/}}
{{- define "graphrag-conversation.namespace" -}}
  {{- .Values.namespaceOverride | default .Release.Namespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Helper functions for labels related to resources
*/}}

{{- define "graphrag-conversation.fullname.service.headless" -}}
  {{- printf "%s-%s" (include "graphrag-conversation.fullname" .) "headless" -}}
{{- end -}}
