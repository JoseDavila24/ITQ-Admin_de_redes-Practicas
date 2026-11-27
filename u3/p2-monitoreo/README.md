# Práctica U3-P2: Monitoreo de tráfico HTTP, DNS y DHCP

Esta práctica reutiliza los servicios de [`u3/p1-log`](../p1-log). Aquí no se levanta nada nuevo: solo se captura su tráfico. En Ubuntu:

```bash
cd ~/ITQ-Admin_de_redes-Practicas/u3/p1-log && docker compose up -d --build
```

> Todos los comandos `docker compose` de esta guía se ejecutan dentro de `u3/p1-log`.

> Sustituye `<IP_UBUNTU>` por la IP del servidor Ubuntu (`hostname -I`) y `<interfaz>` por la interfaz de red de Fedora (`ip a`, por ejemplo `enp1s0`).

**Herramientas:**

| Dónde | Herramienta | Instalación |
| :--- | :--- | :--- |
| Fedora | Wireshark y tshark | `sudo dnf install wireshark` y `sudo usermod -aG wireshark $USER` (cierra sesión y vuelve a entrar para capturar sin `sudo`) |
| Ubuntu | tcpdump | `sudo apt install tcpdump` |

| Parte | Dónde se captura | Por qué |
| :--- | :--- | :--- |
| HTTP | Fedora | Fedora es el cliente: todo el tráfico pasa por su interfaz |
| DNS | Fedora y Ubuntu | En Fedora ves cliente ↔ dnsmasq; en Ubuntu ves además dnsmasq ↔ 8.8.8.8 |
| DHCP | Ubuntu (`br-dhcp`) | La red DHCP está aislada: el tráfico solo existe dentro de Ubuntu |

---

## Parte 1: Análisis del protocolo HTTP

### Preparación: contenido de distintos tipos (en Ubuntu)

`web-server` solo trae la página por defecto ("It works!"). Para comparar tiempos entre tipos de contenido, crea estos archivos dentro del contenedor:

```bash
docker exec web-server sh -c 'cd /usr/local/apache2/htdocs && echo "Hola, esto es texto plano." > texto.txt && echo "{\"practica\": \"p2-monitoreo\", \"ok\": true}" > datos.json && cp ../icons/apache_pb.png imagen.png && dd if=/dev/urandom of=grande.bin bs=1M count=10 2>/dev/null && mkdir -p carpeta && echo "<h1>Carpeta</h1>" > carpeta/index.html && ls -l'
```

| URL | Tipo | Tamaño |
| :--- | :--- | :--- |
| `/` | `text/html` | 191 B |
| `/texto.txt` | `text/plain` | 27 B |
| `/datos.json` | `application/json` | 41 B |
| `/imagen.png` | `image/png` | ~9 KB |
| `/grande.bin` | `application/octet-stream` | 10 MB |
| `/carpeta/` | directorio (para el 301) | – |

> Los archivos se conservan con `docker compose restart`, pero se borran si el contenedor se recrea (`docker compose down` y `up`). En ese caso, repite este comando.

### 1. Iniciar la captura en Fedora

En Wireshark, elige `<interfaz>` con este **filtro de captura**:

```
host <IP_UBUNTU> and tcp port 80
```

O con tshark:

```bash
tshark -i <interfaz> -f "host <IP_UBUNTU> and tcp port 80" -w http.pcap
```

### 2. Generar tráfico desde Fedora

```bash
# Métodos
curl -i http://<IP_UBUNTU>/
curl -i -X POST -d "dato=prueba" http://<IP_UBUNTU>/
curl -I http://<IP_UBUNTU>/
curl -i -X OPTIONS http://<IP_UBUNTU>/

# Códigos de estado
curl -i http://<IP_UBUNTU>/carpeta
curl -i -r 0-9 http://<IP_UBUNTU>/texto.txt
curl -i http://<IP_UBUNTU>/noexiste
curl -i http://<IP_UBUNTU>/.htaccess
```

Para el **304** primero se obtiene la fecha `Last-Modified` y luego se envía en `If-Modified-Since`:

```bash
LM=$(curl -sI http://<IP_UBUNTU>/ | grep -i '^last-modified' | cut -d' ' -f2- | tr -d '\r')
curl -i -H "If-Modified-Since: $LM" http://<IP_UBUNTU>/
```

| Comando | Método | Código | Significado |
| :--- | :--- | :--- | :--- |
| `curl -i /` | GET | 200 OK | Recurso entregado |
| `curl -X POST` | POST | 200 OK | Datos recibidos (la página es estática) |
| `curl -I` | HEAD | 200 OK | Solo cabeceras, sin cuerpo |
| `curl -X OPTIONS` | OPTIONS | 200 OK | Cabecera `Allow` con los métodos permitidos |
| `/carpeta` | GET | 301 Moved Permanently | Redirige a `/carpeta/` (cabecera `Location`) |
| `-r 0-9 /texto.txt` | GET | 206 Partial Content | Solo los bytes 0–9 (cabecera `Range`) |
| `If-Modified-Since` | GET | 304 Not Modified | No cambió; se usa la copia del cliente |
| `/.htaccess` | GET | 403 Forbidden | Acceso prohibido |
| `/noexiste` | GET | 404 Not Found | El recurso no existe |

### 3. Tiempos por tipo de contenido (desde Fedora)

```bash
for f in / texto.txt datos.json imagen.png grande.bin; do
  curl -s -o /dev/null -w "$f  %{content_type}  %{size_download} B  conexión=%{time_connect}s  primer_byte=%{time_starttransfer}s  total=%{time_total}s\n" http://<IP_UBUNTU>/$f
done
```

- `conexión`: tiempo del three-way handshake.
- `primer_byte`: tiempo hasta que llega el primer byte de la respuesta.
- `total`: tiempo hasta recibir el contenido completo. Con archivos pequeños apenas cambia; con `grande.bin` (10 MB) crece mucho.

Detén la captura (botón rojo en Wireshark o `Ctrl+C` en tshark).

### 4. Qué buscar en Wireshark

| Objetivo | Filtro de visualización / dónde mirar |
| :--- | :--- |
| Estructura del paquete | Panel de detalle: Ethernet → IPv4 → TCP → Hypertext Transfer Protocol |
| Cabeceras de solicitud y respuesta | Clic derecho en un paquete HTTP → **Seguir → Flujo HTTP**. Solicitud: `Host`, `User-Agent`, `Accept`. Respuesta: `Server`, `Content-Type`, `Content-Length`, `Last-Modified`, `ETag` |
| Métodos | `http.request.method == "POST"` (o `"GET"`, `"HEAD"`, `"OPTIONS"`) |
| Three-way handshake | `tcp.flags.syn == 1`. SYN (cliente) → SYN, ACK (servidor) → ACK (cliente). El cierre se ve con `tcp.flags.fin == 1` |
| Códigos de estado | `http.response.code == 404` (o 200, 206, 301, 304, 403) |
| Tiempos de respuesta | Columna `http.time` (clic derecho en el campo `[Time since request]` de una respuesta → Aplicar como columna). Compara las filas de `/`, `texto.txt`, `datos.json`, `imagen.png` y `grande.bin`. **Estadísticas → HTTP → Contador de paquetes** muestra cuántas respuestas hubo de cada código |

Resumen con tshark:

```bash
tshark -r http.pcap -Y http -T fields -e frame.number -e http.request.method -e http.request.uri -e http.response.code -e http.response.phrase -e http.content_type -e http.content_length -e http.time
```

```bash
tshark -r http.pcap -Y "tcp.flags.syn == 1" -T fields -e frame.number -e ip.src -e ip.dst -e tcp.srcport -e tcp.dstport -e tcp.flags.str
```

---

## Parte 2: Análisis del protocolo DNS

### 1. Iniciar las capturas

**En Fedora** (cliente ↔ dnsmasq): Wireshark en `<interfaz>` con el filtro de captura `port 53`. O con tshark:

```bash
tshark -i <interfaz> -f "port 53" -w dns-fedora.pcap
```

**En Ubuntu** (resolución completa: cliente ↔ dnsmasq ↔ 8.8.8.8). Por SSH desde Fedora:

```bash
ssh chema@<IP_UBUNTU>
```

```bash
sudo tcpdump -i any -n --print -w ~/dns-ubuntu.pcap port 53
```

> `--print` muestra los paquetes en pantalla mientras los guarda en el archivo. Sin `--print`, `tcpdump -w` no muestra nada hasta que lo detienes con `Ctrl+C`.

### 2. Generar tráfico desde Fedora

```bash
# A - dominio local (lo responde dnsmasq sin salir a Internet)
dig A chema.osvp @<IP_UBUNTU>

# A - externo, dos veces seguidas: la 1ª va a 8.8.8.8, la 2ª sale de caché
dig A google.com @<IP_UBUNTU>; dig A google.com @<IP_UBUNTU>

# AAAA, MX, TXT, CNAME
dig AAAA google.com @<IP_UBUNTU>
dig MX gmail.com @<IP_UBUNTU>
dig TXT google.com @<IP_UBUNTU>
dig CNAME www.github.com @<IP_UBUNTU>

# NXDOMAIN
dig A dominio-falso-99999.com @<IP_UBUNTU>

# Bit RD = 0 (sin recursión pedida)
dig A google.com @<IP_UBUNTU> +norecurse

# Resolución iterativa completa: raíz -> .com -> servidor autoritativo
dig +trace google.com
```

En cada `dig`, la línea `;; Query time: N msec` indica el tiempo de resolución.

Detén las capturas y copia la de Ubuntu a Fedora:

```bash
scp chema@<IP_UBUNTU>:~/dns-ubuntu.pcap .
```

### 3. Qué buscar en Wireshark

| Objetivo | Filtro de visualización / dónde mirar |
| :--- | :--- |
| Estructura de consulta y respuesta | Panel **Domain Name System**: cabecera, **Queries**, **Answers**, **Authority RRs**, **Additional RRs**. La respuesta repite la pregunta y añade las respuestas |
| Campos de cabecera | **Transaction ID** (igual en la consulta y su respuesta), **Flags**: QR (consulta/respuesta), Opcode, AA (autoritativa), TC, RD (recursión deseada), RA (recursión disponible), Rcode (0 = No error, 3 = NXDOMAIN), y contadores Questions / Answer RRs / Authority RRs / Additional RRs |
| Tipos de registro | `dns.qry.type == 1` A · `28` AAAA · `15` MX · `16` TXT · `5` CNAME |
| Errores | `dns.flags.rcode == 3` (NXDOMAIN) |
| Sin recursión | `dns.flags.recdesired == 0` (la consulta de `+norecurse`) |
| Resolución completa (captura de Ubuntu) | Filtro `dns.qry.name == "google.com"`. Se ven 4 paquetes: Fedora → dnsmasq, dnsmasq → 8.8.8.8, 8.8.8.8 → dnsmasq, dnsmasq → Fedora. dnsmasq usa **otro Transaction ID** hacia 8.8.8.8. `chema.osvp` y las respuestas de caché solo tienen 2 paquetes: no salen a Internet |
| Resolución iterativa (captura de Fedora, `dig +trace`) | Consultas a los servidores raíz (`a.root-servers.net`…), luego a los de `.com` (`a.gtld-servers.net`…) y por último a `ns1.google.com`, que responde con AA = 1 |
| Tiempos de resolución | Columna `dns.time` (clic derecho en `[Time]` de la respuesta → Aplicar como columna). Compara: `chema.osvp` y caché ≈ 0–1 ms; primera consulta externa ≈ decenas de ms; `dig +trace` es la más lenta |

Resumen con tshark:

```bash
tshark -r dns-ubuntu.pcap -Y dns -T fields -e frame.time_relative -e ip.src -e ip.dst -e dns.id -e dns.flags.response -e dns.qry.type -e dns.qry.name -e dns.flags.recdesired -e dns.flags.recavail -e dns.flags.authoritative -e dns.flags.rcode -e dns.time
```

Detalle completo de un paquete (por ejemplo el número 2):

```bash
tshark -r dns-ubuntu.pcap -Y "frame.number == 2" -O dns
```

---

## Parte 3: Análisis del protocolo DHCP (desde Ubuntu, red aislada)

Las PCs `pc1` y `pc2` están en la red aislada `red-dhcp` (192.168.50.0/24) con `kea-server` (192.168.50.2). Kea entrega concesiones de **120 s**, con renovación (T1) a los **60 s** y rebind (T2) a los **90 s**.

Usa **dos terminales SSH** al Ubuntu: una para capturar y otra para los comandos (esta última, dentro de `~/ITQ-Admin_de_redes-Practicas/u3/p1-log`).

### 1. Iniciar la captura (terminal 1)

```bash
sudo tcpdump -i br-dhcp -n -e -v --print -w ~/dhcp.pcap 'port 67 or port 68'
```

> Inicia la captura **después** de `docker compose up`: cada `up` crea `br-dhcp` de nuevo.

### 2. Generar tráfico (terminal 2)

**A. Secuencia completa (DORA)**

```bash
docker exec -it pc1 bash -c "ip addr flush dev eth0 && dhclient -v eth0"
docker exec -it pc2 bash -c "ip addr flush dev eth0 && dhclient -v eth0"
```

**B. Renovación automática**

No hay que ejecutar nada: `dhclient` queda corriendo y renueva solo a los ~50–60 s. En la terminal 1 verás un `Request` **unicast** de `192.168.50.10` a `192.168.50.2` y su `ACK`.

**C. Rebind (servidor caído)**

Justo después de ver una renovación (`Request` + `ACK` unicast), detén Kea:

```bash
docker compose stop kea-server
```

1. pc1 intenta renovar por unicast y nadie responde; lo repite varias veces.
2. Unos 90 s después de la última renovación, pasa a **rebind**: envía el `Request` por **broadcast** a `255.255.255.255`.
3. **En cuanto veas ese broadcast**, arranca Kea otra vez:

```bash
docker compose start kea-server
```

Kea responde `ACK` y pc1 conserva su IP. Si esperas más de 120 s, la concesión vence y pc1 empieza de cero con un `Discover`.

Detén la captura con `Ctrl+C` (terminal 1) y cópiala a Fedora:

```bash
scp chema@<IP_UBUNTU>:~/dhcp.pcap .
```

### 3. Qué buscar en Wireshark

| Objetivo | Filtro de visualización / dónde mirar |
| :--- | :--- |
| Secuencia completa | `dhcp`. Tipo de mensaje (opción 53): `dhcp.option.dhcp == 1` Discover · `2` Offer · `3` Request · `5` ACK |
| Contenido de cada mensaje | Panel **Dynamic Host Configuration Protocol**: Message type (Boot Request/Reply), Transaction ID, `ciaddr` (Client IP), `yiaddr` (Your IP), Client MAC address y opciones: 53 tipo, 50 IP solicitada, 54 servidor, 51 lease, 58 T1, 59 T2, 1 máscara, 3 router, 6 DNS |
| Direcciones MAC | `eth.src` / `dhcp.hw.mac_addr` (cada PC tiene la suya). El servidor responde a esa MAC |
| Direcciones IP | Discover y Request: `0.0.0.0 → 255.255.255.255` (el cliente aún no tiene IP). Offer y ACK: `192.168.50.2 → 192.168.50.10`. `yiaddr` = IP asignada |
| Tiempos de lease | En Offer y ACK: opción 51 = **120 s**, 58 (T1) = **60 s**, 59 (T2) = **90 s** |
| Renovación | `dhcp.option.dhcp == 3 && dhcp.ip.client != 0.0.0.0`. Renovación: `ciaddr` = su IP y destino `192.168.50.2` (unicast). Rebind: mismo `ciaddr` pero destino `255.255.255.255` (broadcast) |

Resumen con tshark (una línea por mensaje):

```bash
tshark -r dhcp.pcap -Y dhcp -T fields -E header=y -e frame.time_relative -e eth.src -e ip.src -e ip.dst -e dhcp.option.dhcp -e dhcp.ip.client -e dhcp.ip.your -e dhcp.option.requested_ip_address -e dhcp.option.ip_address_lease_time -e dhcp.option.renewal_time_value -e dhcp.option.rebinding_time_value
```

Ejemplo real de esta práctica (tiempos en segundos desde el inicio de la captura):

| t | Origen → Destino | Tipo | ciaddr | yiaddr | Lease / T1 / T2 | Evento |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 0.0 | 0.0.0.0 → 255.255.255.255 | 1 Discover | 0.0.0.0 | – | – | DORA |
| 0.0 | 192.168.50.2 → 192.168.50.10 | 2 Offer | 0.0.0.0 | 192.168.50.10 | 120 / 60 / 90 | DORA |
| 0.0 | 0.0.0.0 → 255.255.255.255 | 3 Request | 0.0.0.0 | – | – | DORA |
| 0.0 | 192.168.50.2 → 192.168.50.10 | 5 ACK | 0.0.0.0 | 192.168.50.10 | 120 / 60 / 90 | DORA |
| 47.5 | 192.168.50.10 → 192.168.50.2 | 3 Request | 192.168.50.10 | – | – | Renovación (unicast) |
| 47.5 | 192.168.50.2 → 192.168.50.10 | 5 ACK | 192.168.50.10 | 192.168.50.10 | 120 / 60 / 90 | Renovación |
| 94.7 | 192.168.50.10 → 192.168.50.2 | 3 Request | 192.168.50.10 | – | – | Kea detenido: sin respuesta |
| 148.1 | 192.168.50.10 → 255.255.255.255 | 3 Request | 192.168.50.10 | – | – | Rebind (broadcast) |
| 163.7 | 192.168.50.2 → 192.168.50.10 | 5 ACK | 192.168.50.10 | 192.168.50.10 | 120 / 60 / 90 | Kea arrancado: rebind aceptado |

---

## Detener

```bash
cd ~/ITQ-Admin_de_redes-Practicas/u3/p1-log && docker compose down
```
