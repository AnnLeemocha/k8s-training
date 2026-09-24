{{- define "drawio.name" -}}
drawio
{{- end -}}

{{- define "drawio.labels" -}}
app.kubernetes.io/name: {{ include "drawio.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app: drawio
{{- end -}}
