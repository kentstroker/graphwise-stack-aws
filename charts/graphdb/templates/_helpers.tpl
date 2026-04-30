{{- define "graphdb.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}

{{- define "graphdb.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
fullname: defaults to the release name verbatim. Different from the
"prepend chart name if not present" pattern other charts use, because
we deliberately install this chart under multiple release names
(graphdb-embedded, graphdb-projects) and want resources to carry the
release name unchanged so the two instances are easy to tell apart.
*/}}
{{- define "graphdb.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Default TLS Secret name when the user hasn't overridden it.
*/}}
{{- define "graphdb.tlsSecretName" -}}
{{- if .Values.ingress.tlsSecretName -}}
{{- .Values.ingress.tlsSecretName -}}
{{- else -}}
{{- printf "%s-tls" (include "graphdb.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Default Ingress host when not explicitly set. Falls back to extracting
the host from .Values.externalUrl (https://<host>/...).
*/}}
{{- define "graphdb.ingressHost" -}}
{{- if .Values.ingress.host -}}
{{- .Values.ingress.host -}}
{{- else if .Values.externalUrl -}}
{{- regexReplaceAll "^https?://([^/]+).*$" .Values.externalUrl "$1" -}}
{{- else -}}
{{- fail "Either ingress.host or externalUrl must be set" -}}
{{- end -}}
{{- end }}
