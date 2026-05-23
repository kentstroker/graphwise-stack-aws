{{- define "refine.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}
{{- define "refine.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{- define "refine.fullname" -}}{{ .Chart.Name }}{{- end }}
{{- define "refine.host" -}}{{ regexReplaceAll "^https?://([^/]+).*$" .Values.externalUrl "$1" }}{{- end }}
