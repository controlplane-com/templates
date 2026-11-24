{{/*
LibreChat start script, run by /bin/sh (the image is Alpine: no bash).
  1. Point the two upload directories at the shared volume mounted on /app/storage.
  2. Write librechat.yaml (CONFIG_PATH) from the chart values.
  3. Set DOMAIN_CLIENT / DOMAIN_SERVER to the custom domain or the canonical endpoint.
  4. Wait for MongoDB, then create the admin account from the admin secret if there are
     no users yet (the first user is ADMIN), before the UI serves anything.
  5. Start the backend exactly as the image's CMD does.
Embedded with librechat.inlineScript, which doubles every $ for the platform.
*/}}
{{- define "librechat.script.start" -}}
set -eu
cd /app

mkdir -p /app/storage/uploads /app/storage/images
for pair in /app/uploads:/app/storage/uploads /app/client/public/images:/app/storage/images; do
  link="${pair%%:*}"
  target="${pair#*:}"
  if [ ! -L "$link" ]; then
    rm -rf "$link"
    ln -s "$target" "$link"
  fi
done

cat > /tmp/librechat.yaml <<'LIBRECHAT_YAML_EOF'
{{ include "librechat.config" . }}
LIBRECHAT_YAML_EOF

{{- if .Values.customDomain }}
DOMAIN={{ .Values.customDomain | trimSuffix "/" | squote }}
{{- else }}
DOMAIN="${CPLN_GLOBAL_ENDPOINT:-http://localhost:3080}"
{{- end }}
export DOMAIN_CLIENT="$DOMAIN"
export DOMAIN_SERVER="$DOMAIN"
echo "librechat: serving on $DOMAIN"

count_users() {
  node -e 'const m = require(require.resolve("mongoose", { paths: ["/app/api", "/app"] }));
m.connect(process.env.MONGO_URI, { serverSelectionTimeoutMS: 5000 })
  .then(() => m.connection.db.collection("users").countDocuments())
  .then((n) => { process.stdout.write(String(n)); return m.disconnect(); })
  .then(() => process.exit(0))
  .catch((e) => { console.error(e.message); process.exit(1); });'
}

deadline=$(( $(date +%s) + 180 ))
until USERS=$(count_users 2>/tmp/mongo-wait.log); do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "librechat: MongoDB not reachable after 180s:" >&2
    cat /tmp/mongo-wait.log >&2
    exit 1
  fi
  sleep 5
done
echo "librechat: MongoDB reachable, USERS=$USERS"

if [ "$USERS" = "0" ]; then
  echo "librechat: creating the admin account $LIBRECHAT_ADMIN_EMAIL"
  if ! node config/create-user.js "$LIBRECHAT_ADMIN_EMAIL" "Admin" "admin" "$LIBRECHAT_ADMIN_PASSWORD" --email-verified=true; then
    # Another replica may have created it first; only a still-empty database is an error.
    USERS=$(count_users) || USERS=0
    if [ "$USERS" = "0" ]; then
      echo "librechat: admin account creation failed (check the admin secret: email, password of 8+ characters)" >&2
      exit 1
    fi
  fi
fi

exec npm run backend
{{- end }}
