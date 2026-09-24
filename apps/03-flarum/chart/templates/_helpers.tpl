{{- define "flarum.name" -}}
flarum
{{- end -}}

{{- define "flarum.labels" -}}
app.kubernetes.io/name: {{ include "flarum.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app: flarum
{{- end -}}

{{- define "mysql.name" -}}
mysql
{{- end -}}

{{- define "mysql.labels" -}}
app.kubernetes.io/name: {{ include "mysql.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app: mysql
{{- end -}}
