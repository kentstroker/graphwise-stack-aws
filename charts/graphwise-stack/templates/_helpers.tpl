{{- define "graphwise-stack.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}

{{- define "graphwise-stack.baseUrl" -}}
{{- $sub := required "global.subdomain must be set" .Values.global.subdomain -}}
{{- $base := required "global.baseDomain must be set" .Values.global.baseDomain -}}
{{- printf "https://%s.%s" $sub $base -}}
{{- end }}

{{- define "graphwise-stack.authHost" -}}
auth.{{ .Values.global.subdomain }}.{{ .Values.global.baseDomain }}
{{- end }}
