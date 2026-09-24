{{- define "filebrowser.name" -}}
filebrowser
{{- end -}}

{{- define "filebrowser.labels" -}}
app.kubernetes.io/name: {{ include "filebrowser.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app: filebrowser
{{- end -}}
