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
fullname: <release>-<chart> form. In umbrella context, .Chart.Name
resolves to the subchart alias (graphdb-embedded or graphdb-projects)
and .Release.Name is the parent release (graphwise-stack), giving
each instance a distinct, prefixed name:
  graphwise-stack-graphdb-embedded
  graphwise-stack-graphdb-projects
Standalone install (chart name "graphdb") renders as <release>-graphdb.

Was previously `.Release.Name` alone, which assumed the chart would
only ever be installed as separate Helm releases. In umbrella mode,
both subchart aliases share the parent release name, so both rendered
with the same metadata.name and silently collided -- only the second
alias survived in the rendered manifest, leaving PoolParty unable to
reach a graphdb-embedded service that didn't exist.
*/}}
{{- define "graphdb.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
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
