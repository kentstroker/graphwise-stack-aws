{{/*
Expand the name of the chart.
*/}}
{{- define "graphrag-chatbot.name" -}}
  {{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "graphrag-chatbot.fullname" -}}
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
{{- define "graphrag-chatbot.chart" -}}
  {{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "graphrag-chatbot.labels" -}}
helm.sh/chart: {{ include "graphrag-chatbot.chart" . }}
{{ include "graphrag-chatbot.selectorLabels" . }}
app.kubernetes.io/version: {{ coalesce .Values.image.tag .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: graphrag-chatbot
app.kubernetes.io/part-of: graphrag
{{- if .Values.labels -}}
  {{- tpl (toYaml .Values.labels) . | nindent 0 -}}
{{- end -}}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "graphrag-chatbot.selectorLabels" -}}
app.kubernetes.io/name: {{ include "graphrag-chatbot.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "graphrag-chatbot.serviceAccountName" -}}
  {{- if .Values.serviceAccount.create }}
    {{- default (include "graphrag-chatbot.fullname" .) .Values.serviceAccount.name }}
  {{- else }}
    {{- default "default" .Values.serviceAccount.name }}
  {{- end }}
{{- end }}

{{/*
Returns the namespace of the release.
*/}}
{{- define "graphrag-chatbot.namespace" -}}
  {{- .Values.namespaceOverride | default .Release.Namespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Helper functions for labels related to resources
*/}}

{{- define "graphrag-chatbot.fullname.configmap.nginx" -}}
  {{- printf "%s-%s" (include "graphrag-chatbot.fullname" .) "nginx" | trunc 63 | trimSuffix "-" -}}
{{- end -}}
