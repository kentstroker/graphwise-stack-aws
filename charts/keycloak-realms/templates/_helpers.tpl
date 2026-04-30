{{- define "keycloak-realms.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}

{{/*
Compute the base URL once: https://<subdomain>.<baseDomain>. Used as
the parent domain for all per-app subdomains in redirect URIs and
web origins.
*/}}
{{- define "keycloak-realms.baseUrl" -}}
{{- $sub := required "subdomain must be set" .Values.subdomain -}}
{{- $base := required "baseDomain must be set" .Values.baseDomain -}}
{{- printf "https://%s.%s" $sub $base -}}
{{- end }}

{{/*
graphrag's redirect URIs cover the chatbot SPA and the chatbot's
context path. The chatbot is reachable at https://graphrag.<sub>.<base>/.
*/}}
{{- define "keycloak-realms.graphragRedirectUris" -}}
- https://graphrag.{{ .Values.subdomain }}.{{ .Values.baseDomain }}/*
- https://graphrag.{{ .Values.subdomain }}.{{ .Values.baseDomain }}/
{{- end }}
