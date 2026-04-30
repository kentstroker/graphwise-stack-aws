{{- define "poolparty.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}

{{- define "poolparty.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "poolparty.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{- define "poolparty.tlsSecretName" -}}
{{- if .Values.ingress.tlsSecretName -}}
{{- .Values.ingress.tlsSecretName -}}
{{- else -}}
{{- printf "%s-tls" (include "poolparty.fullname" .) -}}
{{- end -}}
{{- end }}

{{- define "poolparty.ingressHost" -}}
{{- if .Values.ingress.host -}}
{{- .Values.ingress.host -}}
{{- else if .Values.externalUrl -}}
{{- regexReplaceAll "^https?://([^/]+).*$" .Values.externalUrl "$1" -}}
{{- else -}}
{{- fail "Either ingress.host or externalUrl must be set" -}}
{{- end -}}
{{- end }}
