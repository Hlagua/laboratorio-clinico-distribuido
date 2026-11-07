#!/usr/bin/env bash
# Certificado AUTOFIRMADO provisional para que Nginx arranque mientras no
# exista el dominio DuckDNS. Se reemplaza con certificado.sh (Let's Encrypt).
# No sobrescribe un certificado que ya exista.
#
# Uso:  ./certificado_temporal.sh <dominio>
set -euo pipefail
DOMINIO="${1:?Indique el dominio (el mismo DOMINIO de infra/.env)}"
DIR="$(cd "$(dirname "$0")" && pwd)/letsencrypt/live/$DOMINIO"

# Los certificados de Let's Encrypt pertenecen a root: se consulta con sudo.
if sudo test -e "$DIR/fullchain.pem"; then
  echo "Ya existe un certificado en $DIR; no se modifica."
  exit 0
fi
mkdir -p "$DIR"
openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
  -keyout "$DIR/privkey.pem" -out "$DIR/fullchain.pem" \
  -subj "/CN=$DOMINIO/O=Laboratorio Clinico (provisional)" 2>/dev/null
chmod 600 "$DIR/privkey.pem"
echo "Certificado provisional creado en $DIR (válido 30 días)"
