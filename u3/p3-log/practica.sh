#!/usr/bin/env bash
# Práctica 03 - Análisis de logs (HTTP, DNS, DHCP + FTP extra)
# Uso: ./practica.sh <comando>
#
#   up          Construye, levanta y asigna IP por DHCP a pc1/pc2
#   http        Parte 1: genera 200/404/403/GET/POST y muestra los logs de Apache
#   dns         Parte 2: genera consultas A/AAAA/MX/CNAME/NXDOMAIN y muestra el querylog
#   dhcp        Parte 3: asignación, renovación, liberación y conflictos de IP
#   ftp         Extra: login correcto y fallido en vsftpd
#   todo        Ejecuta http, dns, dhcp y ftp seguidos
#
#   ver <x>     Sigue un log en vivo (Ctrl+C para salir). x puede ser:
#                 web      access_log + error_log   (dentro del contenedor web)
#                 ftp      /var/log/vsftpd.log      (dentro del contenedor ftp)
#                 leases   /data/dhcpd.leases       (dentro del contenedor dhcp)
#                 dhcp     mensajes de dhcpd        (docker logs)
#                 dns      querylog de BIND         (docker logs)
#   leases      Concesiones del servidor (dhcp) y de los clientes (pc1, pc2)
#   entrar <c>  Abre una terminal dentro del contenedor c (web, dns, dhcp, ftp, pc1, pc2)
#   ps          Estado de los contenedores
#   down        Detiene y elimina todo (los logs se borran)
#   liberar53   Desactiva el stub DNS de systemd-resolved (libera el puerto 53 del host)

set -euo pipefail
cd "$(dirname "$0")"

titulo() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
paso()   { printf '\n\033[1;33m$ %s\033[0m\n' "$*"; }
nota()   { printf '\033[0;32m# %s\033[0m\n' "$*"; }
run()    { paso "$*"; "$@" || true; }

puerto_ocupado() {
  command -v ss >/dev/null 2>&1 && ss -Hlntu "( sport = :$1 )" 2>/dev/null | grep -q .
}

ip_de() { docker exec "$1" sh -c "ip -4 -o addr show eth0 | awk '{print \$4}' | head -1"; }

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
    printf '%s -> %s  (DNS: %s)\n' "$pc" "$(ip_de "$pc")" \
      "$(docker exec "$pc" awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)"
  done
}

up() {
  chmod 644 bind/*
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
  titulo "Listo. Siguiente paso: ./practica.sh http   (o ./practica.sh todo)"
}

# ---------------------------------------------------------------- Parte 1
http() {
  titulo "Parte 1: HTTP - generando peticiones desde pc1 ($(ip_de pc1)) y pc2 ($(ip_de pc2))"
  run docker exec pc1 curl -s -o /dev/null -w '%{http_code}\n' -A "Mozilla/5.0 (PracticaRedes-PC1)" http://web.chema.osvp/
  run docker exec pc1 curl -s -o /dev/null -w '%{http_code}\n' http://web.chema.osvp/no_existe.html
  run docker exec pc2 curl -s -o /dev/null -w '%{http_code}\n' http://web.chema.osvp/secreto/privado.html
  run docker exec pc2 curl -s -o /dev/null -w '%{http_code}\n' -X POST -d "usuario=chema&grupo=redes" http://web.chema.osvp/

  titulo "Log de accesos DENTRO del contenedor web"
  paso "docker exec web tail -n 4 /usr/local/apache2/logs/access_log"
  docker exec web tail -n 4 /usr/local/apache2/logs/access_log
  nota "IP origen | fecha | \"MÉTODO /ruta HTTP/1.1\" | código | bytes | referer | User-Agent | rt=tiempo en µs"

  titulo "Log de errores DENTRO del contenedor web"
  paso "docker exec web tail -n 4 /usr/local/apache2/logs/error_log"
  docker exec web tail -n 4 /usr/local/apache2/logs/error_log
  nota "AH00128 = archivo inexistente (404) | AH01630 = acceso denegado por configuración (403)"
}

# ---------------------------------------------------------------- Parte 2
dns() {
  titulo "Parte 2: DNS - consultas desde pc1 ($(ip_de pc1)) al servidor 192.168.30.4"
  nota "La RESPUESTA se ve en dig (cliente); el querylog del servidor registra la PREGUNTA."
  run docker exec pc1 dig web.chema.osvp A +noall +answer
  run docker exec pc1 dig web.chema.osvp AAAA +noall +comments +authority
  run docker exec pc1 dig www.chema.osvp CNAME +noall +answer
  run docker exec pc1 dig chema.osvp MX +noall +answer
  run docker exec pc1 dig google.com A +noall +answer
  run docker exec pc1 dig +norecurse web.chema.osvp A +noall +answer
  paso "docker exec pc1 dig servidor-fantasma.chema.osvp A"
  docker exec pc1 dig servidor-fantasma.chema.osvp A | grep -E 'status' || true

  titulo "Querylog del servidor DNS (docker logs dns)"
  paso "docker logs dns 2>&1 | grep 'query' | tail -n 9"
  docker logs --tail 100 dns 2>&1 | grep 'query' | tail -n 9 || true
  nota "client IP#puerto (dominio): query: dominio IN TIPO banderas (IP del servidor)"
  nota "Banderas: + = recursión solicitada (RD)  - = no recursiva  E = EDNS  K = cookie"
}

# ---------------------------------------------------------------- Parte 3
siguiente_ip_libre() {
  local i
  for i in $(seq 100 150); do
    docker exec dhcp grep -q "lease 192.168.30.$i " /data/dhcpd.leases || { echo "192.168.30.$i"; return; }
  done
}

dhcp() {
  titulo "Parte 3: DHCP"

  paso "1) Liberación: docker exec pc1 dhclient -r -v eth0"
  docker exec pc1 dhclient -r -v eth0 2>&1 | grep -E 'DHCP' || true

  paso "2) Asignación completa (DORA): docker exec pc1 dhclient -v eth0"
  docker exec pc1 dhclient -v eth0 2>&1 | grep -E 'DHCP|bound' || true

  paso "3) Renovación de la concesión (pc2 vuelve a pedir la IP que ya tiene)"
  docker exec pc2 bash -c 'dhclient -x -sf /bin/true 2>/dev/null; dhclient -v eth0' 2>&1 | grep -E 'DHCP|bound' || true

  local libre; libre=$(siguiente_ip_libre)
  paso "4) Conflicto A: pc2 usa a mano $libre (la siguiente IP libre del rango) y llega un cliente nuevo"
  docker exec pc2 ip addr add "$libre/24" dev eth0 2>/dev/null || true
  nota "El 'cliente nuevo' es una interfaz macvlan con otra MAC creada en pc1; no altera la IP de pc1."
  docker exec pc1 bash -c "ip link del nuevo0 2>/dev/null; ip link add nuevo0 link eth0 type macvlan mode bridge && ip link set nuevo0 up && \
    timeout 30 dhclient -v -1 -sf /bin/true -lf /tmp/nuevo.leases -pf /tmp/nuevo.pid nuevo0; \
    dhclient -x -sf /bin/true -pf /tmp/nuevo.pid 2>/dev/null; ip link del nuevo0" 2>&1 | grep -E 'DHCP|bound' || true
  docker exec pc2 ip addr del "$libre/24" dev eth0 2>/dev/null || true

  local ip_pc1; ip_pc1=$(ip_de pc1 | cut -d/ -f1)
  paso "5) Conflicto B: pc2 solicita la IP de pc1 ($ip_pc1)"
  docker exec pc2 bash -c "cat > /tmp/conflicto.leases <<EOF
lease {
  interface \"eth0\";
  fixed-address $ip_pc1;
  option subnet-mask 255.255.255.0;
  option dhcp-server-identifier 192.168.30.254;
  renew 4 2030/01/01 00:00:00;
  rebind 4 2030/01/01 00:00:00;
  expire 4 2030/01/01 00:00:00;
}
EOF
timeout 20 dhclient -v -1 -sf /bin/true -lf /tmp/conflicto.leases -pf /tmp/conflicto.pid eth0; dhclient -x -sf /bin/true -pf /tmp/conflicto.pid 2>/dev/null" 2>&1 | grep -E 'DHCP|bound' || true

  titulo "Mensajes del servidor DHCP (docker logs dhcp)"
  docker logs --tail 40 dhcp 2>&1 | grep -E 'DHCP|Abandon|ICMP|unavailable' | tail -n 25 || true

  titulo "Archivo de concesiones DENTRO del contenedor dhcp"
  paso "docker exec dhcp cat /data/dhcpd.leases   (último registro de cada IP)"
  leases_servidor
  nota "starts/ends = inicio y fin de la concesión (UTC) | hardware ethernet = MAC | binding state active/free/abandoned"
}

leases_servidor() {
  docker exec dhcp awk '
    /^lease /  {ip=$2; buf=""}
    ip!=""     {buf=buf $0 "\n"}
    /^}/ && ip!="" {last[ip]=buf; if(!(ip in seen)){order[++n]=ip; seen[ip]=1}; ip=""}
    END {for(i=1;i<=n;i++) printf "%s", last[order[i]]}' /data/dhcpd.leases \
    | grep -E 'lease|starts|ends|binding state|hardware|client-hostname|^}' || true
}

leases() {
  titulo "Concesiones del servidor: docker exec dhcp cat /data/dhcpd.leases"
  leases_servidor
  for pc in pc1 pc2; do
    titulo "Concesión vista por el cliente: docker exec $pc cat /var/lib/dhcp/dhclient.leases (última)"
    docker exec "$pc" awk '/^lease/{b=""} {b=b $0 "\n"} END{printf "%s", b}' /var/lib/dhcp/dhclient.leases || true
  done
  nota "dhcp-lease-time = tiempo de concesión en segundos | renew/rebind/expire = cuándo renovar y cuándo caduca"
}

# ---------------------------------------------------------------- Extra
ftp_() {
  titulo "Extra: FTP"
  paso "Login correcto (alumno / osvp2026) + ls"
  docker exec pc1 bash -c 'ftp -inv ftp.chema.osvp <<EOF
user alumno osvp2026
ls
bye
EOF' 2>&1 | grep -E '^(230|530|226)' || true
  paso "Login fallido (clave incorrecta)"
  docker exec pc1 bash -c 'ftp -inv ftp.chema.osvp <<EOF
user alumno clave_incorrecta
bye
EOF' 2>&1 | grep -E '^(230|530)' || true
  titulo "Log DENTRO del contenedor ftp"
  paso "docker exec ftp tail -n 4 /var/log/vsftpd.log"
  docker exec ftp tail -n 4 /var/log/vsftpd.log
}

ver() {
  case "${1:-}" in
    web)    docker exec web tail -n 20 -f /usr/local/apache2/logs/access_log /usr/local/apache2/logs/error_log ;;
    ftp)    docker exec ftp tail -n 20 -f /var/log/vsftpd.log ;;
    leases) docker exec dhcp tail -n 40 -f /data/dhcpd.leases ;;
    dhcp)   docker logs -n 20 -f dhcp ;;
    dns)    docker logs -n 20 -f dns ;;
    *)      echo "Uso: ./practica.sh ver web|dns|dhcp|leases|ftp"; exit 1 ;;
  esac
}

case "${1:-}" in
  up)        up ;;
  dhcp-pcs)  dhcp_pcs ;;
  http)      http ;;
  dns)       dns ;;
  dhcp)      dhcp ;;
  ftp)       ftp_ ;;
  todo)      http; dns; dhcp; ftp_ ;;
  ver)       ver "${2:-}" ;;
  logs)      ver "${2:-}" ;;
  leases)    leases ;;
  entrar)    c="${2:?Indica el contenedor}"; docker exec -it "$c" sh -c 'command -v bash >/dev/null && exec bash || exec sh' ;;
  ps)        docker compose ps ;;
  down)      docker compose down ;;
  liberar53) liberar53 ;;
  *)         sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
