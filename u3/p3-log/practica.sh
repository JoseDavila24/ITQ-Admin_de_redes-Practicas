#!/usr/bin/env bash
# Práctica 03 - Logs (DNS, HTTP, DHCP, FTP)
# Uso: ./practica.sh <comando>
#   up       Prepara permisos, construye, levanta y asigna IP por DHCP a pc1/pc2
#   dhcp-pcs Vuelve a pedir IP por DHCP para pc1 y pc2
#   http     Genera eventos HTTP   (ver: ./practica.sh logs web)
#   dns      Genera eventos DNS    (ver: ./practica.sh logs dns)
#   dhcp     Genera eventos DHCP   (ver: ./practica.sh logs dhcp)
#   ftp      Genera eventos FTP    (ver: ./practica.sh logs ftp)
#   todo     Ejecuta http, dns, dhcp y ftp seguidos
#   logs X   Sigue en vivo los logs del contenedor X (web|dns|dhcp|ftp)
#   leases   Muestra las concesiones DHCP activas
#   ps       Estado de los contenedores
#   down     Detiene y elimina todo
#   liberar53  Desactiva el stub DNS de systemd-resolved (libera el puerto 53 del host)

set -euo pipefail
cd "$(dirname "$0")"

titulo() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
paso()   { printf '\n\033[1;33m$ %s\033[0m\n' "$*"; }
run()    { paso "$*"; "$@" || true; }

puerto_ocupado() {
  local p=$1
  if command -v ss >/dev/null 2>&1; then
    ss -Hlntu "( sport = :$p )" 2>/dev/null | grep -q .
  else
    return 1
  fi
}

liberar53() {
  titulo "Liberando el puerto 53 del host (systemd-resolved)"
  sudo mkdir -p /etc/systemd/resolved.conf.d
  sudo tee /etc/systemd/resolved.conf.d/disable-stub.conf >/dev/null <<'EOF'
[Resolve]
DNSStubListener=no
EOF
  sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  sudo systemctl restart systemd-resolved
}

dhcp_pcs() {
  titulo "Asignando IP por DHCP a pc1 y pc2"
  for pc in pc1 pc2; do
    paso "docker exec $pc bash -c 'ip addr flush dev eth0 && dhclient -v eth0'"
    docker exec "$pc" bash -c "ip addr flush dev eth0 && dhclient -v eth0" 2>&1 | grep -E 'DHCP|bound' || true
  done
  for pc in pc1 pc2; do
    printf '%s -> %s  (DNS: %s)\n' "$pc" "$(docker exec "$pc" sh -c "ip -4 -o addr show eth0 | awk '{print \$4}'")" \
      "$(docker exec "$pc" awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)"
  done
}

up() {
  titulo "Preparando archivos"
  chmod 644 bind/*
  mkdir -p apache/html/secreto
  [ -f apache/html/index.html ] || echo "<h1>Servidor Web Apache - chema.osvp</h1>" > apache/html/index.html
  [ -f apache/html/secreto/privado.html ] || echo "<h1>Area Restringida</h1>" > apache/html/secreto/privado.html

  if puerto_ocupado 53 && ! docker ps --format '{{.Names}}' | grep -qx dns; then
    echo "AVISO: el puerto 53 del host está ocupado (probablemente systemd-resolved)."
    echo "       Ejecuta primero:  ./practica.sh liberar53"
    exit 1
  fi

  titulo "Construyendo y levantando los 6 contenedores"
  docker compose up -d --build
  sleep 3
  docker compose ps
  dhcp_pcs
  titulo "Listo. Prueba con: ./practica.sh todo   (y en otra terminal: ./practica.sh logs web)"
}

http() {
  titulo "Parte 1: HTTP  (docker logs -f web)"
  run docker exec pc1 curl -s -i -A "Mozilla/5.0 (PracticaRedes-PC1)" http://web.chema.osvp/
  run docker exec pc1 curl -s -i http://web.chema.osvp/no_existe.html
  run docker exec pc2 curl -s -i http://web.chema.osvp/secreto/privado.html
  run docker exec pc2 curl -s -i -X POST -d "usuario=chema&grupo=redes" http://web.chema.osvp/
  titulo "Últimas líneas de docker logs web"
  docker logs --tail 4 web
}

dns() {
  titulo "Parte 2: DNS  (docker logs -f dns)"
  run docker exec pc1 dig web.chema.osvp A +short
  run docker exec pc1 dig www.chema.osvp CNAME +short
  run docker exec pc1 dig chema.osvp MX +short
  run docker exec pc1 dig google.com A +short
  run docker exec pc1 dig +norecurse web.chema.osvp A +short
  paso "docker exec pc1 dig servidor-fantasma.chema.osvp A"
  docker exec pc1 dig servidor-fantasma.chema.osvp A | grep -E 'status' || true
  titulo "Consultas registradas en docker logs dns"
  docker logs --tail 80 dns 2>&1 | grep 'query' | tail -8 || true
}

dhcp() {
  titulo "Parte 3: DHCP  (docker logs -f dhcp)"
  run docker exec pc1 dhclient -r -v eth0
  run docker exec pc1 dhclient -v eth0
  paso "docker exec pc2 ip addr add 192.168.30.105/24 dev eth0   (conflicto de IP)"
  docker exec pc2 ip addr add 192.168.30.105/24 dev eth0 2>/dev/null || echo "(la IP .105 ya estaba agregada en pc2)"
  titulo "Últimas líneas de docker logs dhcp"
  docker logs --tail 10 dhcp 2>&1
}

ftp_() {
  titulo "Extra: FTP  (docker logs -f ftp)"
  paso "Login exitoso (alumno / osvp2026) + ls"
  docker exec pc1 bash -c 'ftp -inv ftp.chema.osvp <<EOF
user alumno osvp2026
ls
bye
EOF' || true
  paso "Login fallido (clave incorrecta)"
  docker exec pc1 bash -c 'ftp -inv ftp.chema.osvp <<EOF
user alumno clave_incorrecta
bye
EOF' || true
  titulo "Últimas líneas de docker logs ftp"
  docker logs --tail 10 ftp 2>&1
}

case "${1:-}" in
  up)        up ;;
  dhcp-pcs)  dhcp_pcs ;;
  http)      http ;;
  dns)       dns ;;
  dhcp)      dhcp ;;
  ftp)       ftp_ ;;
  todo)      http; dns; dhcp; ftp_ ;;
  logs)      docker logs -f "${2:?Indica el contenedor: web|dns|dhcp|ftp}" ;;
  leases)    docker exec dhcp cat /data/dhcpd.leases ;;
  ps)        docker compose ps ;;
  down)      docker compose down ;;
  liberar53) liberar53 ;;
  *)         sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
