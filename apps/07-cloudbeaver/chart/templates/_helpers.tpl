{{- define "cloudbeaver.name" -}}
cloudbeaver
{{- end -}}

{{- define "cloudbeaver.labels" -}}
app.kubernetes.io/name: {{ include "cloudbeaver.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app: cloudbeaver
{{- end -}}
