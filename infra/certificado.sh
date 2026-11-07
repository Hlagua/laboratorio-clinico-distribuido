#!/usr/bin/env bash
# Obtiene/renueva el certificado Let's Encrypt con el reto HTTP-01 (webroot).
# Funciona detrás del Azure Load Balancer: si la validación llega a la otra
# VM, su Nginx pide el archivo a esta por la red privada (ver la plantilla).
#
# Los certificados se guardan en infra/letsencrypt (NO en /etc/letsencrypt,
# que pertenece a la práctica de la Unidad 2). Después hay que copiarlos a la
# otra VM y recargar Nginx en ambas.
#
# Uso:  ./certificado.sh <correo> <dominio> [otro-dominio ...]
#   ej. ./certificado.sh henrylagua1@gmail.com labclinico-henry.chilecentral.cloudapp.azure.com
set -euo pipefail

CORREO="${1:?Indique un correo para Lets Encrypt}"
shift
[ $# -ge 1 ] || { echo "Indique al menos un dominio"; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"
DOMINIOS=()
for d in "$@"; do DOMINIOS+=(-d "$d"); done
mkdir -p "$DIR/certbot-www"

docker run --rm \
  -v "$DIR/letsencrypt:/etc/letsencrypt" \
  -v "$DIR/letsencrypt-trabajo:/var/lib/letsencrypt" \
  -v "$DIR/certbot-www:/var/www/certbot" \
  certbot/certbot:latest \
  certonly --webroot -w /var/www/certbot "${DOMINIOS[@]}" \
  --cert-name "$1" --email "$CORREO" --agree-tos --no-eff-email \
  --non-interactive --keep-until-expiring --expand

echo "Certificado en $DIR/letsencrypt/live/$1/"
