{{- /* Every name and the selector carry the release name ({{ .Release.Name }}, set by Argo CD: releaseName),
       so two releases of this chart in one namespace never collide and the Service, PDB and anti-affinity of one
       release never pick the pods of another. */ -}}
{{- define "crl-nginx.labels" -}}
app: crl-nginx
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "crl-nginx.conf" -}}
{{- .Files.Get "files/nginx.conf"
    | replace "S3_HOST" (required "s3.host is required" .Values.s3.host)
    | replace "S3_TENANT" (required "s3.tenant is required" .Values.s3.tenant)
    | replace "S3_BUCKET" (required "s3.bucket is required" .Values.s3.bucket) -}}
{{- end -}}

{{- /* CA bundle for the TLS of S3: caBundle (from common/ca-bundle.values.yaml) wins; fallback files/ca-bundle.pem
       in this chart. Neither = the chart stops. */ -}}
{{- define "crl-nginx.caBundle" -}}
{{- required "CA bundle missing: create common/ca-bundle.values.yaml (or add files/ca-bundle.pem to the chart)"
    (default (.Files.Get "files/ca-bundle.pem") .Values.caBundle) -}}
{{- end -}}
