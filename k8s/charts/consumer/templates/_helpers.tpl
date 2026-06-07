{{/*
Chart name, optionally overridden.
*/}}
{{- define "consumer.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name. Honour fullnameOverride; otherwise fall back to the
chart name (this chart deploys a single named workload, so we keep it stable
rather than prefixing the release name).
*/}}
{{- define "consumer.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "consumer.name" . -}}
{{- end -}}
{{- end -}}

{{/*
Service account name. Defaults to "<fullname>-sa".
*/}}
{{- define "consumer.serviceAccountName" -}}
{{- default (printf "%s-sa" (include "consumer.fullname" .)) .Values.serviceAccount.name -}}
{{- end -}}

{{/*
Name of the SecretProviderClass and the synced k8s Secret (they share a name).
*/}}
{{- define "consumer.secretName" -}}
{{- printf "%s-secrets" (include "consumer.fullname" .) -}}
{{- end -}}

{{/*
Common labels — included on every object.
*/}}
{{- define "consumer.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "consumer.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: guardianlink
{{- end -}}

{{/*
Selector labels — the stable subset used by Deployment/NetworkPolicy selectors.
*/}}
{{- define "consumer.selectorLabels" -}}
app.kubernetes.io/name: {{ include "consumer.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
