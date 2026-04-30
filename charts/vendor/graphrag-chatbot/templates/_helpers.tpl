{{/*
Combined image pull secrets
*/}}
{{- define "graphrag-chatbot.combinedImagePullSecrets" -}}
  {{- $secrets := concat .Values.global.imagePullSecrets .Values.image.pullSecrets }}
  {{- tpl (toYaml $secrets) . -}}
{{- end -}}

{{/*
Renders the container image
*/}}
{{- define "graphrag-chatbot.image" -}}
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
Renders the external URL for the GraphRAG Chatbot UI.
*/}}
{{- define "graphrag-chatbot.external-url" -}}
  {{- tpl .Values.configuration.externalUrl . -}}
{{- end -}}

{{- define "graphrag-chatbot.external-url.host" -}}
  {{- $external_url := urlParse (include "graphrag-chatbot.external-url" .) -}}
  {{- coalesce .Values.ingress.host $external_url.host -}}
{{- end -}}

{{- define "graphrag-chatbot.external-url.path" -}}
  {{- $external_url := urlParse (include "graphrag-chatbot.external-url" .) -}}
  {{- coalesce .Values.ingress.path $external_url.path "/" -}}
{{- end -}}

{{/*
Renders the URL for the Conversation service.
*/}}
{{- define "graphrag-chatbot.conversation.proxy-url" -}}
  {{- tpl .Values.configuration.conversationProxy.url . -}}
{{- end -}}

{{- define "graphrag-chatbot.conversation.proxy-context-path" -}}
  {{- $backendUrl := urlParse (.Values.configuration.properties.GRAPHRAG_BACKEND_URL) -}}
  {{- printf "%s" (coalesce $backendUrl.path "/") -}}
{{- end -}}
