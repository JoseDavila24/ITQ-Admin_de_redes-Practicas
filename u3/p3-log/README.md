# Práctica 03 – Análisis de logs (HTTP, DNS y DHCP)

**Objetivo:** analizar los archivos de registro (logs) de servicios de red en contenedores
(HTTP, DNS y DHCP) e identificar patrones, errores y eventos que permitan diagnosticar su
funcionamiento.

## 0. ¿Qué hay en la red?

Red `192.168.30.0/24`, dominio `chema.osvp`, 6 contenedores:

| Contenedor | Servicio          | IP              | ¿Guarda archivo de log?                                                                  |
|------------|-------------------|-----------------|-------------------------------------------------------------------------------------------|
| `web`      | Apache (HTTP)     | 192.168.30.5    | **Sí:** `/usr/local/apache2/logs/access_log` y `error_log`                                |
| `dns`      | BIND9 (DNS)       | 192.168.30.4    | **No:** la imagen envía todo a la salida del contenedor, así que se ve con `docker logs dns` |
| `dhcp`     | ISC DHCP          | 192.168.30.254  | **No** para los mensajes (`docker logs dhcp`). **Sí** guarda los arrendamientos en `/data/dhcpd.leases` |
| `ftp`      | vsftpd (extra)    | 192.168.30.6    | **Sí:** `/var/log/vsftpd.log`                                                             |
| `pc1`      | Cliente           | 192.168.30.100  | **Sí:** SSH en `/var/log/auth.log` · DHCP del cliente en `/var/log/syslog` · arrendamiento en `/var/lib/dhcp/dhclient.leases` |
| `pc2`      | Cliente           | 192.168.30.101  | Igual que pc1                                                                             |

Los PCs (`pc1`, `pc2`) son Ubuntu con `ip`, `dhclient`, `ssh`, `ping`, `dig`, `curl`, `ftp`,
`rsyslog` (escribe los logs en `/var/log/`, como un Ubuntu normal) y el firewall **ufw activo**. Al arrancar, ufw abre solo el puerto **22 (SSH)** y bloquea las demás
conexiones de entrada.

---

## 1. Teoría breve

### ¿Qué es un log?

Es un archivo o salida donde un servicio anota **cada cosa que hace**: quién se conectó, qué
pidió, qué respondió y si hubo errores. Leer logs sirve para saber si un servicio funciona y,
si falla, por qué.

En Docker hay dos lugares posibles para los logs:

- **Archivo dentro del contenedor:** entras con `docker exec -it <contenedor> sh` y lo lees con `cat` o `tail -f`.
- **Salida del contenedor (stdout/stderr):** cuando la imagen no escribe archivos, se lee desde el host con `docker logs <contenedor>`.

### HTTP en una línea

El navegador (cliente) pide un recurso con un **método** (`GET` = traer, `POST` = enviar datos)
y el servidor contesta con un **código de estado**:

- **200:** OK.
- **404:** no existe.
- **403:** existe o está protegido, pero no tienes permiso.

### DNS: cómo funciona

DNS traduce **nombres** a **direcciones IP**, como una agenda de contactos: tú sabes el nombre
(`web.chema.osvp`) y DNS te da el número (`192.168.30.5`).

```
 pc1                         dns (192.168.30.4)                     Internet
  |  ¿IP de web.chema.osvp?        |                                    |
  |------------------------------->|  "chema.osvp es MI zona,           |
  |  192.168.30.5                  |   lo busco en db.chema.osvp"       |
  |<-------------------------------|                                    |
  |  ¿IP de google.com?            |                                    |
  |------------------------------->|  "no es mía: pregunto por ti"      |
  |                                |----------------------------------->| 8.8.8.8
  |  142.250.x.x                   |<-----------------------------------|
  |<-------------------------------|                                    |
```

Conceptos clave:

- **Zona y registros:** el servidor `dns` es **autoritativo** de la zona `chema.osvp`: tiene
  la lista oficial de sus nombres en `bind/db.chema.osvp`. Cada línea es un **registro**. En esta
  práctica usamos solo el tipo **A** (nombre → IPv4), por ejemplo `web IN A 192.168.30.5`.
  Existen otros tipos: `AAAA` (IPv6), `MX` (correo) y `CNAME` (alias).
- **Consulta recursiva:** el cliente le dice al servidor "encuéntrame la respuesta, cueste lo que
  cueste". Si el nombre no es de su zona, el servidor pregunta a otros (los `forwarders`
  `8.8.8.8` y `1.1.1.1`) y devuelve la respuesta final. `dig` la pide así por defecto, con la
  bandera **RD** (*recursion desired*).
- **Consulta no recursiva** (`dig +norecurse`): el cliente dice "contesta solo con lo que ya
  sabes". Si el nombre es de su zona, responde igual. Si no, no sale a buscarlo y solo devuelve
  pistas: los servidores raíz en la sección AUTHORITY.
- **Códigos de respuesta:**
  - `NOERROR`: todo bien.
  - `NXDOMAIN`: ese nombre no existe.
  - `SERVFAIL`: el servidor no pudo resolverlo, por ejemplo por falta de internet.
- **¿Cómo sabe el PC cuál es su DNS?** Se lo da el servidor DHCP (`option domain-name-servers
  192.168.30.4`) y queda escrito en `/etc/resolv.conf` del PC.
- **Logs:** BIND puede anotar cada **pregunta** (`querylog yes`) y cada **respuesta**
  (`responselog yes`). Ambas opciones están en `bind/named.conf.options`.

### DHCP en una línea

Un equipo nuevo no tiene IP y la pide con 4 mensajes, el proceso **DORA**:

- **D**ISCOVER: "¿hay algún servidor DHCP?"
- **O**FFER: "te ofrezco la `.100`"
- **R**EQUEST: "la quiero"
- **A**CK: "es tuya por 2 minutos"

Antes de que termine ese tiempo, el cliente **renueva** (REQUEST + ACK). Al desconectarse puede
**liberarla** (RELEASE).

---

## 2. Liberar el puerto 53 del host (una sola vez)

El contenedor `dns` publica el puerto 53, que en Ubuntu ocupa `systemd-resolved`. Si ya lo
hiciste en otra práctica, salta este paso.

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
```

```bash
sudo tee /etc/systemd/resolved.conf.d/disable-stub.conf > /dev/null <<'EOF'
[Resolve]
DNS=8.8.8.8 1.1.1.1
DNSStubListener=no
EOF
```

```bash
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
```

```bash
sudo systemctl restart systemd-resolved
```

```bash
sudo systemctl restart docker
```

Comprueba que `cat /etc/resolv.conf` **ya no** dice `127.0.0.53`.

## 3. Levantar la práctica

```bash
cd ~/ITQ-Admin_de_redes-Practicas/u3/p3-log
```

```bash
docker compose up -d --build
```

```bash
docker compose ps
```

Los 6 contenedores deben aparecer en estado `Up`.

## 4. Dar IP por DHCP a los PCs

Docker les pone una IP propia al arrancar. La quitamos y pedimos una al servidor DHCP:

```bash
docker exec pc1 bash -c "ip addr flush dev eth0 && dhclient -v eth0"
```

```bash
docker exec pc2 bash -c "ip addr flush dev eth0 && dhclient -v eth0"
```

Verifica la IP, el DNS recibido y el firewall:

```bash
docker exec pc1 ip a show eth0
```

```bash
docker exec pc1 cat /etc/resolv.conf
```

```bash
docker exec pc1 ufw status verbose
```

Debes ver `inet 192.168.30.100/24`, `nameserver 192.168.30.4` y `Status: active` con
`22/tcp ALLOW IN`.

**SSH** (contraseña `osvp2026`):

```bash
ssh root@192.168.30.100
```

```bash
docker exec -it pc1 ssh root@pc2.chema.osvp
```

El primer comando conecta del host a pc1. El segundo conecta de pc1 a pc2 usando el DNS.

> Los puertos publicados `2223` y `2224` solo sirven **antes** del paso 4: Docker los
> reenvía a la IP original del contenedor, que borramos con `ip addr flush`. Después del DHCP,
> entra por la IP: desde un host Linux la red de Docker se alcanza directamente.

Para abrir otro puerto en el firewall de un PC (ejemplo, el 80):

```bash
docker exec pc1 ufw allow 80/tcp
```

---

## 5. Cómo ver los logs (resumen)

Usa **dos terminales**: en la **Terminal 1** dejas el log abierto (`-f` = seguir en vivo,
`Ctrl+C` para salir); en la **Terminal 2** generas el tráfico desde pc1/pc2.

| Servicio                 | Entrar al contenedor        | Ver el log en vivo                                                   |
|--------------------------|-----------------------------|----------------------------------------------------------------------|
| web (HTTP)               | `docker exec -it web sh`    | `tail -f /usr/local/apache2/logs/access_log /usr/local/apache2/logs/error_log` |
| dns (DNS)                | `docker exec -it dns bash`  | *(sin archivo de log)* desde el host: `docker logs -f dns`           |
| dhcp – mensajes          | —                           | *(sin archivo de log)* desde el host: `docker logs -f dhcp`          |
| dhcp – arrendamientos    | `docker exec -it dhcp bash` | `tail -f /data/dhcpd.leases`                                         |
| pc1 – su arrendamiento   | `docker exec -it pc1 bash`  | `cat /var/lib/dhcp/dhclient.leases`                                  |
| pc1 – DHCP del cliente   | `docker exec -it pc1 bash`  | `tail -f /var/log/syslog`                                            |
| pc1/pc2 – SSH            | `docker exec -it pc2 bash`  | `tail -f /var/log/auth.log`                                          |
| ftp                      | `docker exec -it ftp bash`  | `tail -f /var/log/vsftpd.log`                                        |

`web` usa Alpine, que no tiene `bash`; por eso se entra con `sh`. Para salir de un
contenedor: `exit`.

---

## Parte 1 – Logs HTTP

El servidor muestra su **página por defecto** ("It works!").

**Terminal 1** – entra al servidor web y sigue sus logs:

```bash
docker exec -it web sh
```

```sh
tail -f /usr/local/apache2/logs/access_log /usr/local/apache2/logs/error_log
```

**Terminal 2** – una petición por cada caso:

```bash
docker exec pc1 curl -i -A "Navegador-PC1" http://web.chema.osvp/
```

Esta da 200 (GET) y lleva un User-Agent propio.

```bash
docker exec pc1 curl -i http://web.chema.osvp/noexiste.html
```

Esta da 404.

```bash
docker exec pc2 curl -i http://web.chema.osvp/.htaccess
```

Esta da 403: Apache protege los archivos `.ht*`.

```bash
docker exec pc2 curl -i -X POST -d "usuario=chema" http://web.chema.osvp/
```

Esta es un POST (envío de formulario).

**Lo que aparece en `access_log`:**

```
192.168.30.100 [25/Nov/2026:14:13:45 +0000] "GET / HTTP/1.1" 200 191 "Navegador-PC1" 317us
192.168.30.100 [25/Nov/2026:14:13:45 +0000] "GET /noexiste.html HTTP/1.1" 404 236 "curl/7.81.0" 288us
192.168.30.101 [25/Nov/2026:14:13:45 +0000] "GET /.htaccess HTTP/1.1" 403 239 "curl/7.81.0" 188us
192.168.30.101 [25/Nov/2026:14:13:45 +0000] "POST / HTTP/1.1" 200 191 "curl/7.81.0" 231us
```

**Lo que aparece en `error_log`:**

```
[authz_core:error] [client 192.168.30.101:49000] AH01630: client denied by server configuration: /usr/local/apache2/htdocs/.htaccess
```

Cómo leer una línea de `access_log` (el formato está definido en `apache/httpd.conf`):

```
192.168.30.100  [25/Nov/2026:14:13:45 +0000]  "GET / HTTP/1.1"  200  191   "Navegador-PC1"  317us
   IP origen         fecha y hora               método y ruta  código bytes   User-Agent     tiempo
```

| Qué identificar      | Dónde está                                                            |
|----------------------|------------------------------------------------------------------------|
| 200 OK               | `"GET / HTTP/1.1" 200` y `"POST / HTTP/1.1" 200`                       |
| 404 Not Found        | `"GET /noexiste.html HTTP/1.1" 404`                                    |
| 403 Forbidden        | `"GET /.htaccess HTTP/1.1" 403` y, en `error_log`, `AH01630 client denied` |
| Métodos GET / POST   | `"GET …"` / `"POST …"`                                                 |
| IP de origen         | Primer campo: `192.168.30.100` = pc1, `192.168.30.101` = pc2          |
| User-Agent           | Entre comillas: `"Navegador-PC1"` (puesto con `-A`), `"curl/7.81.0"` (por defecto) |
| Tiempo de respuesta  | Último campo: `317us` = 317 microsegundos = 0.317 ms                  |

---

## Parte 2 – Logs DNS

Para la demostración usamos **un solo tipo de consulta: A** (nombre → IPv4).

> **Sin archivo de log:** la imagen `ubuntu/bind9` arranca BIND en primer plano (`named -g`) y
> manda todos sus mensajes a la salida del contenedor, sin escribir archivos. Por eso se usa
> `docker logs dns`. Dentro del contenedor sí puedes ver la configuración y la zona:
> `docker exec dns cat /etc/bind/db.chema.osvp`.

**Terminal 1:**

```bash
docker logs -f dns
```

**Terminal 2** – 4 consultas tipo A:

```bash
docker exec pc1 dig web.chema.osvp A
```

Consulta exitosa: el nombre está en nuestra zona.

```bash
docker exec pc1 dig noexiste.chema.osvp A
```

Error de resolución: NXDOMAIN.

```bash
docker exec pc1 dig google.com A
```

Consulta recursiva: el DNS sale a internet.

```bash
docker exec pc1 dig +norecurse google.com A
```

Consulta no recursiva: el DNS no sale a buscarla.

**La respuesta en el cliente (`dig`)**, por ejemplo para `web.chema.osvp`:

```
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 32220
;; flags: qr aa rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1
;; ANSWER SECTION:
web.chema.osvp.		86400	IN	A	192.168.30.5
```

- `status`: el código de respuesta.
- `aa`: la respuesta es autoritativa (es nuestra zona).
- `rd`: el cliente pidió recursión.
- `ra`: el servidor la permite.
- `ANSWER`: la IP que se respondió.

**Lo que aparece en `docker logs dns`:** por cada consulta salen dos líneas, una `query:`
(pregunta) y otra `response:` (respuesta).

```
192.168.30.100#59575 (web.chema.osvp): query: web.chema.osvp IN A +E(0)K (192.168.30.4)
192.168.30.100#59575 (web.chema.osvp): response: web.chema.osvp IN A NOERROR 1 0 1 +E(0)K (192.168.30.4)
192.168.30.100#41144 (noexiste.chema.osvp): query: noexiste.chema.osvp IN A +E(0)K (192.168.30.4)
192.168.30.100#41144 (noexiste.chema.osvp): response: noexiste.chema.osvp IN A NXDOMAIN 0 1 1 +E(0)K (192.168.30.4)
192.168.30.100#44119 (google.com): query: google.com IN A -E(0)K (192.168.30.4)
192.168.30.100#44119 (google.com): response: google.com IN A NOERROR 0 13 1 -E(0)K (192.168.30.4)
```

Cómo leer una línea:

```
192.168.30.100#59575  (web.chema.osvp): response: web.chema.osvp IN A  NOERROR  1 0 1   +      (192.168.30.4)
 IP#puerto origen        dominio                                  tipo  código  conteos recursión  IP del servidor
```

- **Conteos `1 0 1`:** número de registros en las secciones ANSWER, AUTHORITY y ADDITIONAL.
  Un `1` en ANSWER significa que sí hubo respuesta.
- **Recursión:** `+` = recursiva (RD activado); `-` = no recursiva.
- **Otras letras:** `E` = el cliente usa EDNS; `K` = envía una *cookie* DNS.

| Qué identificar             | Dónde está                                                                   |
|-----------------------------|-------------------------------------------------------------------------------|
| Tipo de consulta            | `IN A`                                                                        |
| Dominios consultados        | `(web.chema.osvp)`, `(noexiste.chema.osvp)`, `(google.com)`                   |
| Respuestas proporcionadas   | Línea `response:` → `NOERROR 1 0 1`, `NXDOMAIN …`; la IP concreta está en `dig` (ANSWER) |
| Recursiva vs no recursiva   | `+` en `dig google.com` · `-` en `dig +norecurse google.com`: responde `NOERROR 0 13 1`, sin respuesta (0), solo 13 pistas (los servidores raíz) |
| Error NXDOMAIN              | `response: noexiste.chema.osvp IN A NXDOMAIN` · en `dig`: `status: NXDOMAIN` |
| Origen de las consultas     | `192.168.30.100#59575` = IP y puerto del cliente (pc1)                        |

Con internet, la consulta recursiva a `google.com` devuelve `NOERROR` con un `1` en ANSWER.
Si tu red bloquea el DNS externo verás `SERVFAIL`, que también es un error para documentar.

---

## Parte 3 – Logs DHCP

La concesión dura **2 minutos** (`default-lease-time 120` en `dhcpd.conf`), así que los PCs
**renuevan solos cada minuto** y lo verás en el log sin hacer nada.

> **Sin archivo de log:** `dhcpd` envía sus mensajes por syslog y el contenedor no tiene un
> servidor syslog. Por eso los mensajes se ven con `docker logs dhcp`. Lo que **sí** guarda
> dentro del contenedor es el archivo de **arrendamientos**: `/data/dhcpd.leases`.

**Terminal 1** – mensajes del servidor:

```bash
docker logs -f dhcp
```

**Terminal 3 (opcional)** – arrendamientos dentro del contenedor:

```bash
docker exec -it dhcp bash
```

```bash
tail -f /data/dhcpd.leases
```

**Terminal 2** – genera los eventos en este orden:

**a) Asignación (DORA):** ya ocurrió en el paso 4. Repítela con pc1 si quieres:

```bash
docker exec pc1 dhclient -v eth0
```

**b) Renovación:** no hagas nada; espera 1 minuto y mira la Terminal 1.

**c) Liberación:**

```bash
docker exec pc1 dhclient -r -v eth0
```

```bash
docker exec pc1 dhclient -v eth0
```

El primero libera la IP y el segundo vuelve a pedirla (DORA completo).

**d) Conflicto de IP:** pc2 se pone **a mano** la `192.168.30.102`, la siguiente libre. Luego
llega un "equipo nuevo": pc1 cambia su MAC. Antes de ofrecer una IP, el servidor hace ping
(`ping-check true`). Como pc2 responde, la marca como ocupada y ofrece otra.

```bash
docker exec pc2 ip addr add 192.168.30.102/24 dev eth0
```

```bash
docker exec pc1 bash -c "ip link set eth0 down && ip link set eth0 address 02:00:00:00:00:99 && ip link set eth0 up && dhclient -v eth0"
```

Para dejar todo como estaba:

```bash
docker exec pc2 ip addr del 192.168.30.102/24 dev eth0
```

```bash
docker compose restart pc1
```

```bash
docker exec pc1 bash -c "ip addr flush dev eth0 && dhclient -v eth0"
```

**e) Lo mismo visto desde el cliente.** Cada PC tiene su propio log de `dhclient` y el archivo
de su arrendamiento:

```bash
docker exec -it pc2 bash
```

```bash
tail -f /var/log/syslog
```

```bash
cat /var/lib/dhcp/dhclient.leases
```

**Lo que aparece en `docker logs dhcp`:**

```
DHCPDISCOVER from 02:00:00:00:00:01 via eth0                                       <- a) DORA
DHCPOFFER on 192.168.30.100 to 02:00:00:00:00:01 (pc1) via eth0
DHCPREQUEST for 192.168.30.100 (192.168.30.254) from 02:00:00:00:00:01 (pc1) via eth0
DHCPACK on 192.168.30.100 to 02:00:00:00:00:01 (pc1) via eth0
DHCPREQUEST for 192.168.30.101 from 02:00:00:00:00:02 (pc2) via eth0               <- b) renovación
DHCPACK on 192.168.30.101 to 02:00:00:00:00:02 (pc2) via eth0
DHCPRELEASE of 192.168.30.100 from 02:00:00:00:00:01 (pc1) via eth0 (found)        <- c) liberación
ICMP Echo reply while lease 192.168.30.102 valid.                                  <- d) conflicto
Abandoning IP address 192.168.30.102: pinged before offer
DHCPOFFER on 192.168.30.103 to 02:00:00:00:00:99 (pc1) via eth0
```

**Lo que hay en `/data/dhcpd.leases` (servidor):**

```
lease 192.168.30.101 {
  starts 3 2026/11/25 14:13:23;
  ends 3 2026/11/25 14:15:23;
  binding state active;
  hardware ethernet 02:00:00:00:00:02;
  client-hostname "pc2";
}
lease 192.168.30.102 {
  binding state abandoned;
}
```

**Lo que aparece en `/var/log/syslog` del cliente (pc2):** la asignación y, un minuto
después, la renovación (REQUEST directo al servidor `192.168.30.254`, sin DISCOVER):

```
Nov 25 14:21:05 pc2 dhclient[176]: bound to 192.168.30.101 -- renewal in 57 seconds.
Nov 25 14:22:02 pc2 dhclient[176]: DHCPREQUEST for 192.168.30.101 on eth0 to 192.168.30.254 port 67 (xid=0x546f3d42)
Nov 25 14:22:02 pc2 dhclient[176]: DHCPACK of 192.168.30.101 from 192.168.30.254 (xid=0x423d6f54)
Nov 25 14:22:02 pc2 dhclient[176]: bound to 192.168.30.101 -- renewal in 55 seconds.
```

**Lo que hay en `/var/lib/dhcp/dhclient.leases` (cliente pc2):**

```
lease {
  fixed-address 192.168.30.101;
  option dhcp-lease-time 120;
  option domain-name-servers 192.168.30.4;
  renew 3 2026/11/25 14:14:19;
  rebind 3 2026/11/25 14:15:08;
  expire 3 2026/11/25 14:15:23;
}
```

| Qué identificar                    | Dónde está                                                                      |
|------------------------------------|----------------------------------------------------------------------------------|
| DISCOVER / OFFER / REQUEST / ACK   | `docker logs dhcp` (a)                                                           |
| MAC de los clientes                | `from 02:00:00:00:00:01 (pc1)` · `hardware ethernet` en `dhcpd.leases`. Son fijas: pc1 `…:01`, pc2 `…:02` |
| IP asignada y tiempo de concesión  | `DHCPACK on 192.168.30.100` · `starts`/`ends` (2 min) · en el cliente: `dhcp-lease-time 120`, `renew`, `expire` |
| Renovaciones                       | `DHCPREQUEST` + `DHCPACK` **sin** DISCOVER antes, cada ~1 minuto (b) · en el cliente: `/var/log/syslog` |
| Liberación (DHCPRELEASE)           | `DHCPRELEASE of 192.168.30.100 … (found)` (c)                                    |
| Conflicto de IP                    | `ICMP Echo reply …` + `Abandoning IP address …: pinged before offer` · `binding state abandoned` (d) |

Las fechas de los logs y de `dhcpd.leases` están en **UTC** (en México, 6 horas más que la hora local).

---

## Extra – Logs SSH

Cada PC guarda los accesos por SSH en **`/var/log/auth.log`**, dentro del contenedor: inicios de
sesión correctos, contraseñas incorrectas, usuarios que no existen y desconexiones.

**Terminal 1** – entra a pc2 y sigue su log de SSH:

```bash
docker exec -it pc2 bash
```

```bash
tail -f /var/log/auth.log
```

**Terminal 2** – conéctate a pc2 desde pc1. Prueba los tres casos:

```bash
docker exec -it pc1 ssh root@pc2.chema.osvp
```

La primera vez SSH pregunta `Are you sure you want to continue connecting (yes/no)?`: escribe
`yes`. Con la contraseña correcta (`osvp2026`) entras; luego escribe `exit`.

```bash
docker exec -it pc1 ssh root@pc2.chema.osvp
```

Esta vez escribe una contraseña incorrecta.

```bash
docker exec -it pc1 ssh alumno@pc2.chema.osvp
```

El usuario `alumno` no existe en pc2.

También puedes conectarte desde el host a la IP: `ssh root@192.168.30.101` (ver paso 4).

**Lo que aparece en `/var/log/auth.log` de pc2:**

```
Nov 25 14:20:59 pc2 sshd[1]: Server listening on 0.0.0.0 port 22.
Nov 25 14:21:05 pc2 sshd[195]: Accepted password for root from 192.168.30.100 port 48050 ssh2
Nov 25 14:21:05 pc2 sshd[195]: pam_unix(sshd:session): session opened for user root(uid=0) by (uid=0)
Nov 25 14:21:05 pc2 sshd[195]: Disconnected from user root 192.168.30.100 port 48050
Nov 25 14:21:05 pc2 sshd[195]: pam_unix(sshd:session): session closed for user root
Nov 25 14:21:07 pc2 sshd[207]: Failed password for root from 192.168.30.100 port 48058 ssh2
Nov 25 14:21:08 pc2 sshd[209]: Invalid user alumno from 192.168.30.100 port 48066
Nov 25 14:21:10 pc2 sshd[209]: Failed password for invalid user alumno from 192.168.30.100 port 48066 ssh2
```

Cómo leer una línea:

```
Nov 25 14:21:05   pc2     sshd[195]:   Accepted password  for root   from 192.168.30.100 port 48050
 fecha y hora    equipo  programa[PID]    resultado        usuario       IP y puerto de origen
```

| Qué buscar                   | Línea en `auth.log`                                          |
|------------------------------|--------------------------------------------------------------|
| Inicio de sesión correcto    | `Accepted password for root from …`                          |
| Contraseña incorrecta        | `Failed password for root from …`                            |
| Usuario que no existe        | `Invalid user alumno from …`                                 |
| Abrir y cerrar sesión        | `session opened for user root` / `session closed for user root` |
| IP de origen                 | `from 192.168.30.100` (pc1)                                  |

Atajos para resumir el log:

```bash
docker exec pc2 grep "Failed password" /var/log/auth.log
```

Muestra solo los intentos fallidos.

```bash
docker exec pc2 lastb
```

Lista los inicios de sesión fallidos (usuario, IP y hora).

## Extra – Logs FTP

**Terminal 1:**

```bash
docker exec -it ftp bash
```

```bash
tail -f /var/log/vsftpd.log
```

**Terminal 2** – un login correcto y uno fallido:

```bash
docker exec pc1 bash -c 'ftp -inv ftp.chema.osvp <<EOF
user alumno osvp2026
ls
bye
EOF'
```

```bash
docker exec pc1 bash -c 'ftp -inv ftp.chema.osvp <<EOF
user alumno mala
bye
EOF'
```

```
CONNECT: Client "192.168.30.100"
[alumno] OK LOGIN: Client "192.168.30.100"
[alumno] FAIL LOGIN: Client "192.168.30.100"
```

## Apagar

```bash
docker compose down
```

Al bajar los contenedores también se borran sus logs.

---

## Errores comunes

| Error | Causa y solución |
|-------|------------------|
| `lookup registry-1.docker.io on 127.0.0.53:53 … connection refused` | Se desactivó el stub DNS pero `/etc/resolv.conf` sigue apuntando a `127.0.0.53`. Repite el paso 2 completo (sobre todo `ln -sf` y los reinicios). |
| `Bind for 0.0.0.0:53 failed: port is already allocated` o `address already in use` | Algo del host usa el puerto. Revisa con `sudo ss -lntup \| grep -E ':(53\|80\|21) '`. El 53 suele ser systemd-resolved (paso 2); el 80, `apache2`/`nginx` (`sudo systemctl stop apache2`); el 21, `vsftpd` (`sudo systemctl stop vsftpd`). |
| `container name "/dns" is already in use` o `Pool overlaps with other one` | La práctica de `u2` sigue levantada: usa los mismos nombres y la misma subred. `cd ../../u2/p2-dhcp && docker compose down`. |
| `429 Too Many Requests` | Límite de descargas de Docker Hub. Espera unos minutos o usa `docker login`. |
| `permission denied … docker.sock` | `sudo usermod -aG docker $USER` y vuelve a iniciar sesión. |
| `Could not resolve host: web.chema.osvp` en un PC | Al PC le falta el paso 4: no tiene el DNS `192.168.30.4` en `/etc/resolv.conf`. |
| `ssh -p 2223 localhost` no responde | Después del DHCP entra por la IP: `ssh root@192.168.30.100` (ver paso 4). |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | Reconstruiste los PCs y cambió su llave SSH: `ssh-keygen -R 192.168.30.100`. |
| Un contenedor queda en `Restarting` | Error de sintaxis en su configuración: mira `docker logs <contenedor>` y revisa el archivo que menciona (`bind/*`, `apache/httpd.conf` o `dhcpd.conf`). |
| `AVISO: no se pudo activar ufw` en `docker logs pc1` | El kernel del host no permitió el firewall en el contenedor. La práctica funciona igual, pero sin firewall en ese PC. |

---

## Archivos

```
p3-log/
├── .env                  # IPs, puertos y contraseñas
├── compose.yaml          # los 6 contenedores
├── Dockerfile.pc         # imagen de pc1/pc2: ip, dhclient, ssh, ufw, rsyslog, dig, curl, ftp
├── dhcpd.conf            # rango .100–.150, concesión de 2 min, ping-check
├── bind/
│   ├── named.conf.options   # recursión, forwarders, querylog y responselog
│   ├── named.conf.local     # declara la zona chema.osvp
│   └── db.chema.osvp        # registros A de la zona
└── apache/
    └── httpd.conf        # página por defecto, protección .ht*, formato del log con User-Agent y tiempo
```
