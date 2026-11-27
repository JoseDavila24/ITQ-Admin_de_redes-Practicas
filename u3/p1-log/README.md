# Práctica U3-P1: Análisis de logs HTTP, DNS y DHCP con Docker Compose

Un solo `compose.yaml` levanta **tres servicios independientes** y **dos PCs cliente**:

| Contenedor | Imagen | Red | Log (dentro del contenedor) |
| :--- | :--- | :--- | :--- |
| `web-server` | `httpd:alpine` | host (Ubuntu) | `/usr/local/apache2/logs/access.log` y `error.log` |
| `dns-server` | `joelnb/dnsmasq:latest` | host (Ubuntu) | `/var/log/dnsmasq.log` |
| `kea-server` | `scjalliance/kea-dhcp4-minimal:3.2` | `red-dhcp` (aislada) – IP `192.168.50.2` | `/var/log/kea/kea-dhcp4.log` |
| `pc1`, `pc2` | `pc-cliente` (se construye con `Dockerfile.pc`) | `red-dhcp` (aislada) | – |

```
             LAN real (DHCP de tu red le da la IP a Ubuntu)
  Fedora ──────────────────────────────┐
  (curl / dig / Wireshark)             │
                                 ┌─────┴──────────────────────────────┐
                                 │ Ubuntu Server (Docker)             │
                                 │  web-server  :80   (network host)  │
                                 │  dns-server  :53   (network host)  │
                                 │                                    │
                                 │  br-dhcp 192.168.50.1 (aislada)    │
                                 │   ├─ kea-server 192.168.50.2       │
                                 │   ├─ pc1  (DHCP .10–.50)           │
                                 │   └─ pc2  (DHCP .10–.50)           │
                                 └────────────────────────────────────┘
```

## ¿Por qué no hay conflictos?

| Riesgo | Cómo se evita |
| :--- | :--- |
| Kea compitiendo con el DHCP que le da la IP a Ubuntu | Kea vive solo en el bridge `red-dhcp`. Docker no reenvía los broadcast DHCP del bridge a la LAN y Ubuntu no pide IP en `br-dhcp`. |
| dnsmasq repartiendo IPs | `dnsmasq.conf` **no** tiene `dhcp-range`: solo hace DNS. |
| Puerto 53 ocupado por `systemd-resolved` | dnsmasq usa `bind-dynamic` + `except-interface=lo`: no toca `127.0.0.53`, así **no hay que detener `systemd-resolved`** y Ubuntu conserva su propio DNS. |
| La IP de Ubuntu cambia (la recibe por DHCP) | `bind-dynamic` se adapta solo a la IP nueva; Apache escucha en `0.0.0.0:80`. En esta guía se usa `<IP_UBUNTU>`. |
| Pool de Kea pisando IPs de Docker | Docker solo asigna `192.168.50.1–.6` (`ip_range .0/29`); Kea reparte `.10–.50`. |

**Firewall:** las reglas actuales de ufw (22, 53/udp, 53/tcp, 80) son suficientes. No hace falta abrir 67/68 porque el DHCP no sale de la red aislada.

---

## 0. Despliegue

En Ubuntu Server:

```bash
hostname -I
```

> La primera IP es `<IP_UBUNTU>` (por ejemplo `192.168.122.137`). Úsala en todas las pruebas desde Fedora.

```bash
cd u3/p1-log
```

```bash
docker compose up -d --build
```

```bash
docker compose ps
```

Deben aparecer `web-server`, `dns-server`, `kea-server`, `pc1` y `pc2` en estado *running*.

---

## Parte 1: Análisis de logs HTTP (Apache)

### Configuración aplicada

- `http/httpd-logs.conf` se incluye en `httpd.conf` y define:
  - Formato `combinedtime` = `combined` **+ `%D`** (tiempo de respuesta en microsegundos).
  - `access.log` y `error.log` como archivos dentro del contenedor.
  - `/privado/` con `Require all denied` → **403**.
- `http/htdocs/` contiene `index.html` (con formulario POST), `privado/` y `.htaccess`.

### Pruebas desde Fedora

```bash
# 200 OK - GET
curl -i http://<IP_UBUNTU>/

# 200 OK - POST (envío de formulario)
curl -i -X POST -d "dato=prueba" http://<IP_UBUNTU>/

# 404 Not Found - recurso inexistente
curl -i http://<IP_UBUNTU>/noexiste

# 403 Forbidden - directorio protegido
curl -i http://<IP_UBUNTU>/privado/

# 403 Forbidden - archivo .htaccess (bloqueado por defecto)
curl -i http://<IP_UBUNTU>/.htaccess

# User-Agent distinto (simula un navegador)
curl -i -A "Mozilla/5.0 (X11; Fedora; Linux x86_64) Firefox/133.0" http://<IP_UBUNTU>/
```

También puedes abrir `http://<IP_UBUNTU>/` en el navegador de Fedora y pulsar **Enviar** en el formulario. Así verás el User-Agent real del navegador.

### Ver los logs

```bash
docker exec -it web-server cat /usr/local/apache2/logs/access.log
```

```bash
docker exec -it web-server cat /usr/local/apache2/logs/error.log
```

En tiempo real (en otra terminal mientras haces las pruebas):

```bash
docker exec -it web-server tail -f /usr/local/apache2/logs/access.log
```

Filtrar por código o método:

```bash
docker exec -it web-server grep '" 404 ' /usr/local/apache2/logs/access.log
docker exec -it web-server grep '" 403 ' /usr/local/apache2/logs/access.log
docker exec -it web-server grep '"POST ' /usr/local/apache2/logs/access.log
```

### Tabla de identificación

| Criterio | Ubicación en la línea | Ejemplo |
| :--- | :--- | :--- |
| **IP de origen** | Primer campo | `192.168.122.1` (gateway NAT) o la IP de Fedora |
| **Método** | Primera palabra entre comillas | `"GET / HTTP/1.1"`, `"POST / HTTP/1.1"` |
| **Código 200 / 404 / 403** | Número después de la petición | `200`, `404`, `403` |
| **User-Agent** | Penúltima cadena entre comillas | `"curl/8.9.1"`, `"Mozilla/5.0 ..."` |
| **Tiempo de respuesta** | Último campo (`%D`, microsegundos) | `412` → 0.412 ms |

Ejemplos:

```
192.168.122.1 - - [27/Nov/2026:18:00:00 +0000] "GET / HTTP/1.1" 200 571 "-" "curl/8.9.1" 402
192.168.122.1 - - [27/Nov/2026:18:00:03 +0000] "POST / HTTP/1.1" 200 571 "-" "curl/8.9.1" 380
192.168.122.1 - - [27/Nov/2026:18:00:05 +0000] "GET /noexiste HTTP/1.1" 404 196 "-" "curl/8.9.1" 295
192.168.122.1 - - [27/Nov/2026:18:00:07 +0000] "GET /privado/ HTTP/1.1" 403 199 "-" "curl/8.9.1" 310
```

> En `error.log` también aparece el 403 de `/privado/` como `AH01630: client denied by server configuration`.

---

## Parte 2: Análisis de logs DNS (dnsmasq)

### Configuración aplicada (`dns/dnsmasq.conf`)

| Directiva | Función |
| :--- | :--- |
| `no-resolv` | No usa `/etc/resolv.conf`; solo los `server=` definidos |
| `server=8.8.8.8` / `1.1.1.1` | Upstream para consultas recursivas |
| `address=/chema.osvp/10.10.10.20` | Respuesta local para el dominio `chema.osvp` (la IP es de prueba; puedes cambiarla) |
| `bind-dynamic` | Escucha en la IP de cada interfaz y se adapta si cambia |
| `except-interface=lo` | No escucha en loopback → convive con `systemd-resolved` |
| `log-queries=extra` | Log detallado con ID de consulta y origen |
| `log-facility=/var/log/dnsmasq.log` | Archivo de log dentro del contenedor |

### Pruebas desde Fedora

```bash
# 1. Tipo A + dominio local -> respuesta de config (no recursiva)
dig A chema.osvp @<IP_UBUNTU>

# 2. Tipo AAAA + dominio externo -> recursiva (forwarded)
dig AAAA google.com @<IP_UBUNTU>

# 3. Tipo MX + dominio externo -> recursiva
dig MX gmail.com @<IP_UBUNTU>

# 4. Tipo CNAME + dominio externo -> recursiva
dig CNAME www.google.com @<IP_UBUNTU>

# 5. A de google.com dos veces seguidas -> la 2ª sale de caché
dig A google.com @<IP_UBUNTU>
dig A google.com @<IP_UBUNTU>

# 6. No recursiva explícita (bit RD = 0)
dig A google.com @<IP_UBUNTU> +norecurse

# 7. Error NXDOMAIN
dig A dominio-falso-99999.com @<IP_UBUNTU>
```

> En la salida de `dig` revisa `flags:`. Con `rd` el cliente pidió recursión; con `+norecurse` desaparece `rd`. `status: NXDOMAIN` indica que el dominio no existe.

### Ver los logs

```bash
docker exec -it dns-server cat /var/log/dnsmasq.log
```

```bash
docker exec -it dns-server tail -f /var/log/dnsmasq.log
```

Filtrar:

```bash
docker exec -it dns-server grep chema.osvp /var/log/dnsmasq.log
docker exec -it dns-server grep google.com /var/log/dnsmasq.log
docker exec -it dns-server grep NXDOMAIN /var/log/dnsmasq.log
docker exec -it dns-server grep -E "forwarded|cached|config" /var/log/dnsmasq.log
```

### Tabla de identificación

| Criterio | Patrón en `/var/log/dnsmasq.log` | Ejemplo |
| :--- | :--- | :--- |
| **Origen** | `from <IP_CLIENTE>` | `from 192.168.122.1` |
| **Tipo de consulta** | `query[TIPO]` | `query[A]`, `query[AAAA]`, `query[MX]`, `query[CNAME]` |
| **Dominio** | Nombre tras `query[TIPO]` | `query[A] chema.osvp` |
| **Recursiva** | `forwarded <dominio> to 8.8.8.8` | `forwarded google.com to 8.8.8.8` |
| **No recursiva (caché)** | `cached` sin `forwarded` | `cached google.com is 142.250.x.x` |
| **No recursiva (local)** | `config` sin `forwarded` | `config chema.osvp is 10.10.10.20` |
| **Respuesta** | `reply <dominio> is <valor>` | `reply google.com is 142.250.115.101` |
| **Error NXDOMAIN** | `reply <dominio> is NXDOMAIN` | `reply dominio-falso-99999.com is NXDOMAIN` |

---

## Parte 3: Análisis de logs DHCP (Kea)

### Configuración aplicada (`dhcp/kea-dhcp4.conf`)

| Bloque | Función |
| :--- | :--- |
| `interfaces-config` | Kea escucha en `eth0` (su interfaz en `red-dhcp`) |
| `lease-database` `memfile` | Concesiones en `/var/lib/kea/kea-leases4.csv` |
| `valid-lifetime` / `renew-timer` / `rebind-timer` | Concesión 120 s; renovación a 60 s; rebind a 90 s |
| `pools` | Reparte `192.168.50.10 – 192.168.50.50` |
| `option-data` | Gateway `192.168.50.1` y DNS `8.8.8.8, 1.1.1.1` |
| `loggers` | `/var/log/kea/kea-dhcp4.log`, nivel `DEBUG` 50 (DORA completo) |

> Para capturar con Wireshark (sección 4), **inicia la captura antes** de ejecutar estos eventos.

### A. Asignación inicial (DORA)

```bash
docker exec -it pc1 bash -c "ip addr flush dev eth0 && dhclient -v eth0"
```

```bash
docker exec -it pc1 ip a show eth0
```

Haz lo mismo con `pc2`:

```bash
docker exec -it pc2 bash -c "ip addr flush dev eth0 && dhclient -v eth0"
```

En el log: `DHCPDISCOVER`, `DHCPOFFER`, `DHCPREQUEST`, `DHCPACK` y `DHCP4_LEASE_ALLOC`.

### B. Renovación

```bash
docker exec -it pc1 dhclient -v -1 eth0
```

En el log: `DHCP4_LEASE_REUSE` (ver nota de la tabla).

### C. Conflicto (NAK)

Verifica la IP de `pc1` (ej. `192.168.50.10`) y fuerza a `pc2` a pedirla:

```bash
docker exec -it pc2 bash -c 'dhclient -r eth0; ip addr flush dev eth0; echo "send dhcp-requested-address 192.168.50.10;" > /etc/dhcp/dhclient.conf; dhclient -v eth0'
```

En el log: `DHCPNAK`. `pc2` insiste varias veces y Kea le responde NAK cada vez. Detén `dhclient` con `Ctrl+C`.

Después, quita la petición forzada de `pc2` y pide una IP normal:

```bash
docker exec -it pc2 bash -c 'echo "" > /etc/dhcp/dhclient.conf'
```

```bash
docker exec -it pc2 bash -c "ip addr flush dev eth0 && dhclient -v eth0"
```

### D. Liberación

```bash
docker exec -it pc1 dhclient -r -v eth0
```

En el log: `DHCPRELEASE` y `DHCP4_RELEASE`.

### Ver los logs

```bash
docker exec -it kea-server cat /var/log/kea/kea-dhcp4.log
```

```bash
docker exec -it kea-server tail -f /var/log/kea/kea-dhcp4.log
```

Filtrar eventos clave:

```bash
docker exec -it kea-server grep -E "DHCP4_PACKET_RECEIVED|DHCP4_PACKET_SEND|DHCP4_LEASE_ALLOC|DHCP4_LEASE_REUSE|DHCP4_INIT_REBOOT|DHCP4_RELEASE|DHCPNAK|DHCP4_DECLINE" /var/log/kea/kea-dhcp4.log
```

Concesiones actuales:

```bash
docker exec -it kea-server cat /var/lib/kea/kea-leases4.csv
```

### Tabla de identificación

| Evento / Objetivo | Mensaje clave en el log | Ejemplo |
| :--- | :--- | :--- |
| **DHCPDISCOVER** | `DHCP4_PACKET_RECEIVED ... DHCPDISCOVER (type 1)` | `... DHCPDISCOVER (type 1) received from 0.0.0.0` |
| **DHCPOFFER** | `DHCP4_PACKET_SEND ... DHCPOFFER (type 2)` | `... DHCPOFFER (type 2) ... to 192.168.50.10:68` |
| **DHCPREQUEST** | `DHCP4_PACKET_RECEIVED ... DHCPREQUEST (type 3)` | `... DHCPREQUEST (type 3)` |
| **DHCPACK** | `DHCP4_PACKET_SEND ... DHCPACK (type 5)` | `... DHCPACK (type 5) ... to 192.168.50.10:68` |
| **MAC del cliente** | `[hwtype=1 <MAC>]` | `[hwtype=1 9e:d4:ea:d5:14:a6]` |
| **IP asignada + tiempo de concesión** | `DHCP4_LEASE_ALLOC ... lease <IP> has been allocated for <N> seconds` | `lease 192.168.50.10 has been allocated for 120 seconds` |
| **Renovación** | `DHCP4_LEASE_REUSE ... has been reused for <N> seconds` | `lease 192.168.50.10 has been reused for 104 seconds` |
| **Cliente pide IP previa (INIT-REBOOT)** | `DHCP4_INIT_REBOOT ... requests address <IP>` | `requests address 192.168.50.10` |
| **Liberación (DHCPRELEASE)** | `DHCPRELEASE (type 7)` + `DHCP4_RELEASE` | `address 192.168.50.10 was released properly` |
| **Conflicto de IP (DHCPNAK)** | `DHCPNAK (type 6)` | `DHCP4_PACKET_SEND ... DHCPNAK (type 6)` |
| **Conflicto detectado por el cliente (DHCPDECLINE)** | `DHCP4_DECLINE_LEASE` | `Received DHCPDECLINE for addr 192.168.50.11` |

> **Nota:** la renovación aparece como `DHCP4_LEASE_REUSE` (no `DHCP4_LEASE_RENEW`) porque `dhclient -1` provoca un **INIT-REBOOT**: el cliente pide su IP anterior y Kea reutiliza la concesión extendiéndola otros 120 s. El efecto práctico es el mismo que una renovación.

---

## 4. Captura DHCP con Wireshark desde otra máquina

El tráfico DHCP **solo existe dentro de Ubuntu**, en el bridge `br-dhcp`, porque está aislado a propósito. Ninguna otra máquina de la LAN lo ve por la red. Por eso se captura en `br-dhcp` y se envía a Wireshark por **SSH** (el puerto 22 ya está abierto).

Comprueba la interfaz en Ubuntu:

```bash
ip a show br-dhcp
```

Instala tcpdump en Ubuntu (si no está):

```bash
sudo apt install -y tcpdump
```

### Opción A: archivo `.pcap` (la más simple)

En Ubuntu:

```bash
sudo tcpdump -i br-dhcp -w ~/dhcp.pcap 'port 67 or port 68'
```

Ejecuta los eventos A–D de la Parte 3 y detén la captura con `Ctrl+C`. En Fedora:

```bash
scp chema@<IP_UBUNTU>:~/dhcp.pcap .
```

```bash
wireshark dhcp.pcap
```

### Opción B: en vivo por SSH

Para que `sudo` no pida contraseña a `tcpdump` (solo una vez, en Ubuntu):

```bash
echo "chema ALL=(root) NOPASSWD: /usr/bin/tcpdump" | sudo tee /etc/sudoers.d/tcpdump
```

```bash
sudo chmod 440 /etc/sudoers.d/tcpdump
```

En Fedora:

```bash
ssh chema@<IP_UBUNTU> "sudo tcpdump -i br-dhcp -U -w - 'port 67 or port 68'" | wireshark -k -i -
```

También puedes usar en Wireshark la interfaz **SSH remote capture (sshdump)**: host `<IP_UBUNTU>`, usuario `chema`, interfaz `br-dhcp`, filtro `port 67 or port 68` y la casilla *Use sudo on the remote machine*.

### Filtros útiles en Wireshark

| Filtro | Muestra |
| :--- | :--- |
| `dhcp` | Todo el tráfico DHCP |
| `dhcp.option.dhcp == 1` | DHCPDISCOVER |
| `dhcp.option.dhcp == 2` | DHCPOFFER |
| `dhcp.option.dhcp == 3` | DHCPREQUEST |
| `dhcp.option.dhcp == 5` | DHCPACK |
| `dhcp.option.dhcp == 6` | DHCPNAK |
| `dhcp.option.dhcp == 7` | DHCPRELEASE |
| `dhcp.hw.mac_addr == <MAC>` | Un cliente concreto |

---

## 5. Limpieza

```bash
docker compose down
```

Para borrar también la imagen de los PCs:

```bash
docker compose down --rmi local
```

> Como `systemd-resolved` nunca se detuvo, no hay que reactivar nada. Las reglas de ufw (53 y 80) puedes dejarlas o quitarlas con `sudo ufw delete allow 53/udp`, `sudo ufw delete allow 53/tcp` y `sudo ufw delete allow 80/tcp`.

---

## Solución de problemas

| Síntoma | Causa / solución |
| :--- | :--- |
| `dns-server` se detiene con `address already in use` | Otro proceso usa el 53 en una IP que no es loopback. Revísalo con `sudo ss -lunp 'sport = :53'`. Como último recurso: `sudo systemctl stop systemd-resolved` y `docker compose up -d dns-server`. |
| Fedora no recibe respuesta DNS/HTTP | Revisa que usas la IP actual de Ubuntu (`hostname -I`); pudo cambiar por DHCP. |
| `docker logs kea-server` muestra `DHCP4_ALREADY_RUNNING` | PID viejo. El `command` del compose ya lo borra; si persiste, `docker compose up -d --force-recreate kea-server`. |
| Los logs muestran `192.168.122.1` en vez de la IP de Fedora | Fedora sale por NAT de la red virtual. Pon ambas máquinas en la misma red para ver la IP real. |
| Todas las consultas a `google.com` salen como `forwarded` | El TTL expiró. Repite la consulta inmediatamente después de la primera para ver `cached`. |
| `pc1`/`pc2` no obtienen IP | Comprueba que Kea arrancó: `docker exec -it kea-server tail /var/log/kea/kea-dhcp4.log`. |
