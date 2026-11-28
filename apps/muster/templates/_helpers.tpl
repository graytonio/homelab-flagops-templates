{{- define "muster.configKey" -}}
{{ . | trimPrefix "config/" | replace "/" "__" }}
{{- end -}}
