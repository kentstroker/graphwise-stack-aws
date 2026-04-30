{{/*
Combined image pull secrets
*/}}
{{- define "graphrag-workflows.combinedImagePullSecrets" -}}
  {{- $secrets := concat .Values.global.imagePullSecrets .Values.image.pullSecrets }}
  {{- tpl (toYaml $secrets) . -}}
{{- end -}}

{{/*
Renders the container image
*/}}
{{- define "graphrag-workflows.image" -}}
  {{- $repository := .Values.image.repository -}}
  {{- $tag := .Values.image.tag | default .Chart.AppVersion | toString -}}
  {{- $image := printf "%s:%s" $repository $tag -}}
  {{/* Add registry if present */}}
  {{- $registry := .Values.global.imageRegistry | default .Values.image.registry -}}
  {{- if $registry -}}
    {{- $image = printf "%s/%s" $registry $image -}}
  {{- end -}}
  {{/* Add SHA digest if provided */}}
  {{- if .Values.image.digest -}}
    {{- $image = printf "%s@%s" $image .Values.image.digest -}}
  {{- end -}}
  {{- $image -}}
{{- end -}}

{{/*
Renders the external URL for the GraphRAG N8N workflow engine.
*/}}

{{- define "graphrag-workflows.external-url" -}}
  {{- tpl .Values.configuration.externalUrl . -}}
{{- end -}}

{{- define "graphrag-workflows.external-url.host" -}}
  {{- $external_url := urlParse (include "graphrag-workflows.external-url" .) -}}
  {{- coalesce .Values.ingress.host $external_url.host -}}
{{- end -}}

{{/*
Ensures a trailing slash for proper static resource loading.
*/}}
{{- define "graphrag-workflows.external-url.path" -}}
  {{- $external_url := urlParse (include "graphrag-workflows.external-url" .) -}}
  {{- printf "%s/" ($external_url.path | trimSuffix "/") -}}
{{- end -}}

{{- define "graphrag-workflows.external-url.ingress-path" -}}
  {{- $external_url := urlParse (include "graphrag-workflows.external-url" .) -}}
  {{- coalesce .Values.ingress.path (include "graphrag-workflows.external-url.path" .) -}}
{{- end -}}
