#!/usr/bin/env bash
# Despliega/actualiza el proyecto en una VM. Se ejecuta EN la VM.
# Espera en /tmp: laboratorio.tgz (código, sin credenciales), api.env,
# sync.env e infra.env (generados con infra/generar_env.py).
#   ssh azureuser@<vm> 'bash -s' < infra/desplegar.sh
# Opcional: /tmp/admin.tgz (build de Angular) y /tmp/portal.tgz (build de Flutter).
set -e
cd /opt/laboratorio
tar -xzf /tmp/laboratorio.tgz
sed -i 's/\r$//' infra/*.sh
install -m 600 /tmp/api.env api/.env
install -m 600 /tmp/sync.env sync-worker/.env
install -m 600 /tmp/infra.env infra/.env
rm -f /tmp/api.env /tmp/sync.env /tmp/infra.env /tmp/laboratorio.tgz
mkdir -p web/portal web/admin infra/certbot-www
# Los builds se reemplazan por dentro: Nginx tiene montadas las carpetas.
if [ -f /tmp/admin.tgz ]; then find web/admin -mindepth 1 -delete; tar -xzf /tmp/admin.tgz -C web/admin; rm /tmp/admin.tgz; fi
if [ -f /tmp/portal.tgz ]; then find web/portal -mindepth 1 -delete; tar -xzf /tmp/portal.tgz -C web/portal; rm /tmp/portal.tgz; fi
DOMINIO=$(grep '^DOMINIO=' infra/.env | cut -d= -f2 | tr -d "'")
bash infra/certificado_temporal.sh "$DOMINIO"
cd infra && docker compose up -d --build 2>&1 | tail -3
sleep 12
docker compose ps --format "table {{.Name}}\t{{.Status}}"
echo "health local: $(curl -s http://localhost:8080/health)"
