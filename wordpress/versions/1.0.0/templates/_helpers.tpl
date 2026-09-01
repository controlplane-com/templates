{{/* Resource Naming */}}

{{- define "wordpress.name" -}}
{{- printf "%s-wordpress" .Release.Name }}
{{- end }}

{{- define "wordpress.volume.name" -}}
{{- printf "%s-wordpress-vs" .Release.Name }}
{{- end }}

{{- define "wordpress.identity.name" -}}
{{- printf "%s-wordpress-identity" .Release.Name }}
{{- end }}

{{- define "wordpress.policy.name" -}}
{{- printf "%s-wordpress-policy" .Release.Name }}
{{- end }}

{{- define "wordpress.policy.gvc.name" -}}
{{- printf "%s-wordpress-gvc-policy" .Release.Name }}
{{- end }}

{{/* Boot wrapper: GVC guard -> docroot seed -> wp-config -> install -> Apache. */}}
{{- define "wordpress.secret.start.name" -}}
{{- printf "%s-wordpress-start" .Release.Name }}
{{- end }}

{{/* First-run installer, run before Apache binds. */}}
{{- define "wordpress.secret.install.name" -}}
{{- printf "%s-wordpress-install" .Release.Name }}
{{- end }}

{{/* PHP ini overlay (upload size, memory limit). */}}
{{- define "wordpress.secret.phpini.name" -}}
{{- printf "%s-wordpress-php-ini" .Release.Name }}
{{- end }}

{{/*
Names of the two secrets this chart CREATES for the bundled mariadb subchart.
mariadb 1.4.0 stopped creating its own secrets and now takes only their NAMES,
and a parent cannot template a subchart value — so the names are plain values
that both sides read.
*/}}
{{- define "wordpress.secret.db.name" -}}
{{- .Values.mariadb.credentialsSecretName }}
{{- end }}

{{- define "wordpress.secret.dbRoot.name" -}}
{{- .Values.mariadb.rootPasswordSecretName }}
{{- end }}


{{/* Dependency Helpers (deterministic on .Release.Name — mirrors the subchart helper) */}}

{{/*
Hostname of the bundled MariaDB (the mariadb subchart's `maria.name` helper →
{release}-maria), on port 3306. Always the FQDN: the bare short name is not
reliable and is workload-type dependent.
*/}}
{{- define "wordpress.mariadb.host" -}}
{{- printf "%s-maria.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{/*
Every workload this release creates, as workload links.

Defined ONCE and appended at every `workload-list` call site, so an
`internalAccess.type: workload-list` can never silently cut this release off
from itself. Each member is gated on the toggle that creates it, so the list
never names a workload that was not rendered.

Nothing in this release currently calls INTO WordPress (the traffic runs the
other way, WordPress → MariaDB, and is governed by `mariadb.internalAccess`), so
these entries are defensive rather than load-bearing today. They are here
because a hand-maintained list is exactly what drifts when that changes.
*/}}
{{- define "wordpress.ownWorkloadLinks" -}}
{{- $gvc := .Values.global.cpln.gvc -}}
- //gvc/{{ $gvc }}/workload/{{ include "wordpress.name" . }}
- //gvc/{{ $gvc }}/workload/{{ .Release.Name }}-maria
{{- if .Values.mariadb.phpMyAdmin }}{{- if .Values.mariadb.phpMyAdmin.enabled }}
- //gvc/{{ $gvc }}/workload/{{ .Release.Name }}-phpmyadmin
{{- end }}{{- end }}
{{- if .Values.mariadb.backup }}{{- if .Values.mariadb.backup.enabled }}
- //gvc/{{ $gvc }}/workload/{{ .Release.Name }}-maria-backup
{{- end }}{{- end }}
{{- end }}


{{/* Labeling */}}

{{- define "wordpress.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "wordpress.validate" -}}

{{- /* Admin account — a REQUIRED prerequisite secret, never a values default. */ -}}
{{- if not .Values.admin.secretName -}}
{{- fail "wordpress: admin.secretName is required — the name of a prerequisite `dictionary` secret holding exactly the keys `username`, `password` and `email`. It MUST exist BEFORE install: the admin account is created before Apache binds, and a missing secret wedges the deployment silently (cpln logs returns nothing — read status.versions[].message from `cpln workload get-deployments`)" -}}
{{- end -}}

{{- /* Bundled-database plumbing this chart creates. */ -}}
{{- if not .Values.mariadb.credentialsSecretName -}}
{{- fail "wordpress: mariadb.credentialsSecretName is required — this chart CREATES that dictionary secret from mariadb.credentials.*, and the bundled MariaDB reads it by name. Secret names are org-wide, so give each wordpress release its own name" -}}
{{- end -}}
{{- if not .Values.mariadb.rootPasswordSecretName -}}
{{- fail "wordpress: mariadb.rootPasswordSecretName is required — this chart CREATES that opaque secret from mariadb.credentials.rootPassword, and the bundled MariaDB reads it by name. Secret names are org-wide, so give each wordpress release its own name" -}}
{{- end -}}
{{- if not .Values.mariadb.credentials.username -}}
{{- fail "wordpress: mariadb.credentials.username is required" -}}
{{- end -}}
{{- if not .Values.mariadb.credentials.password -}}
{{- fail "wordpress: mariadb.credentials.password is required" -}}
{{- end -}}
{{- if not .Values.mariadb.credentials.database -}}
{{- fail "wordpress: mariadb.credentials.database is required" -}}
{{- end -}}
{{- if not .Values.mariadb.credentials.rootPassword -}}
{{- fail "wordpress: mariadb.credentials.rootPassword is required" -}}
{{- end -}}
{{- if eq .Values.mariadb.credentialsSecretName .Values.mariadb.rootPasswordSecretName -}}
{{- fail "wordpress: mariadb.credentialsSecretName and mariadb.rootPasswordSecretName must be DIFFERENT secrets — the application credential is deliberately separate from root, so sharing the first does not hand out the second" -}}
{{- end -}}

{{- /*
  Location — the ONE GVC location this release runs in. It is what CONFINES the
  WordPress workload: `defaultOptions` scales to 0 everywhere and `localOptions`
  supplies the real count here. The platform does NOT validate this direction —
  a localOptions entry naming a location the GVC lacks is accepted, stored, and
  simply inert — so the render-time checks below catch the shapes we can see and
  the boot-time GVC read in start.sh catches the rest, best-effort.
*/ -}}
{{- if hasKey .Values "locations" -}}
{{- fail "wordpress: `locations` (plural) is not a key of this chart. WordPress runs in exactly ONE location — one docroot volume and one bundled database — so use the singular `location`, e.g. `location: aws-us-east-1`" -}}
{{- end -}}
{{- if not .Values.location -}}
{{- fail "wordpress: `location` is required — it names the ONE location of your GVC that WordPress runs in, e.g. `location: aws-us-east-1`. Every replica is pinned there and no other location of the GVC starts one" -}}
{{- end -}}
{{- if not (kindIs "string" .Values.location) -}}
{{- fail "wordpress: `location` must be a single location NAME, e.g. `location: aws-us-east-1`. WordPress runs in exactly one location: the docroot is one volume and the bundled database is one instance" -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]+(-[a-z0-9]+)*$" .Values.location) -}}
{{- fail (printf "wordpress: `location` must be a bare location NAME like `aws-us-east-1`, got '%s'. A link form (`//location/x`, which is what `spec.staticPlacement.locationLinks` contains) or a comma-separated list is accepted by Helm AND by the API, and stores a placement that matches no real location — so WordPress starts NOWHERE, every location reports `deactivated because maxScale is set to 0`, and the logs are silent." .Values.location) -}}
{{- end -}}

{{- /* Replicas. */ -}}
{{- if lt (int .Values.wordpress.replicas) 1 -}}
{{- fail (printf "wordpress: wordpress.replicas must be at least 1, got '%v'" .Values.wordpress.replicas) -}}
{{- end -}}

{{- /* Table prefix: WordPress requires a non-empty, [A-Za-z0-9_] prefix. */ -}}
{{- if not .Values.wordpress.tablePrefix -}}
{{- fail "wordpress: wordpress.tablePrefix must not be empty (WordPress default is 'wp_')" -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9_]+$" .Values.wordpress.tablePrefix) -}}
{{- fail (printf "wordpress: wordpress.tablePrefix may contain only letters, numbers and underscores, got '%s'" .Values.wordpress.tablePrefix) -}}
{{- end -}}

{{- /* Site URL must carry a scheme — it becomes WP_HOME/WP_SITEURL verbatim. */ -}}
{{- if .Values.wordpress.siteUrl -}}
{{- if not (or (hasPrefix "http://" .Values.wordpress.siteUrl) (hasPrefix "https://" .Values.wordpress.siteUrl)) -}}
{{- fail (printf "wordpress: wordpress.siteUrl must start with http:// or https:// — it is used verbatim as WP_HOME and WP_SITEURL, got '%s'" .Values.wordpress.siteUrl) -}}
{{- end -}}
{{- if hasSuffix "/" .Values.wordpress.siteUrl -}}
{{- fail (printf "wordpress: wordpress.siteUrl must not end with a trailing slash, got '%s'" .Values.wordpress.siteUrl) -}}
{{- end -}}
{{- end -}}

{{- /* Volume capacity. */ -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
{{- fail (printf "wordpress: volumeset.capacity must be at least 10 (GiB), got '%v'" .Values.volumeset.capacity) -}}
{{- end -}}

{{- /* Access. */ -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "wordpress: internalAccess.type must be 'none', 'same-gvc', 'same-org' or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and (eq .Values.internalAccess.type "workload-list") (not .Values.internalAccess.workloads) -}}
{{- fail "wordpress: internalAccess.workloads must list at least one workload link when internalAccess.type is 'workload-list', e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME (this release's own workloads are added automatically)" -}}
{{- end -}}

{{- /*
  The database is reached over the GVC's internal network. If the user narrows
  the bundled MariaDB to a workload list that omits this WordPress workload, the
  site cannot reach its own database — and it fails as a boot hang, not as an
  error, so catch it at render instead.
*/ -}}
{{- if .Values.mariadb.internalAccess -}}
{{- if eq (.Values.mariadb.internalAccess.type | default "") "workload-list" -}}
{{- $self := printf "//gvc/%s/workload/%s" .Values.global.cpln.gvc (include "wordpress.name" .) -}}
{{- if not (has $self (.Values.mariadb.internalAccess.workloads | default list)) -}}
{{- fail (printf "wordpress: mariadb.internalAccess.type is 'workload-list' but the list does not include this release's WordPress workload — add '%s', or the site cannot reach its own database" $self) -}}
{{- end -}}
{{- end -}}
{{- if eq (.Values.mariadb.internalAccess.type | default "") "none" -}}
{{- fail "wordpress: mariadb.internalAccess.type must not be 'none' — WordPress reaches the bundled database over the GVC internal network. Use 'same-gvc' (default) or 'workload-list' including this release's WordPress workload" -}}
{{- end -}}
{{- end -}}

{{- end }}
