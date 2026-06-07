{{- define "producer.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "producer.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "producer.name" . -}}
{{- end -}}
{{- end -}}

{{- define "producer.serviceAccountName" -}}
{{- default (printf "%s-sa" (include "producer.fullname" .)) .Values.serviceAccount.name -}}
{{- end -}}

{{- define "producer.secretName" -}}
{{- printf "%s-secrets" (include "producer.fullname" .) -}}
{{- end -}}

{{- define "producer.rosterConfigMap" -}}
{{- printf "%s-roster" (include "producer.fullname" .) -}}
{{- end -}}

{{- define "producer.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "producer.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: guardianlink
{{- end -}}

{{- define "producer.selectorLabels" -}}
app.kubernetes.io/name: {{ include "producer.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
