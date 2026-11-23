# Práctica 03 – Análisis de logs (HTTP, DNS, DHCP)

**Objetivo:** analizar los archivos de registro (logs) de servicios de red en contenedores
e identificar patrones, errores y eventos para diagnosticar su funcionamiento.

| Contenedor | Servicio       | IP             | Shell  | Log del servicio                                         |
|------------|----------------|----------------|--------|----------------------------------------------------------|
| `web`      | Apache         | 192.168.30.5   | `sh`   | `/usr/local/apache2/logs/access_log` y `error_log`       |
| `dns`      | BIND9          | 192.168.30.4   | `bash` | Solo en `docker logs dns` (ver nota en la Parte 2)       |
| `dhcp`     | ISC DHCP       | 192.168.30.254 | `bash` | `/data/dhcpd.leases` + mensajes en `docker logs dhcp`    |
| `ftp`      | vsftpd         | 192.168.30.6   | `bash` | `/var/log/vsftpd.log`                                    |
| `pc1/pc2`  | Clientes       | .100 / .101    | `bash` | `/var/lib/dhcp/dhclient.leases` (concesión del cliente)  |

---

## 1. Liberar el puerto 53 del host

Ubuntu usa `systemd-resolved`, que ocupa el puerto 53 (`127.0.0.53`). El contenedor `dns`
también lo necesita, así que hay que desactivar ese "stub". **Los 4 pasos son necesarios y en este orden.**

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

Comprueba que quedó bien:

```bash
cat /etc/resolv.conf
```

Debe mostrar servidores reales (`nameserver 8.8.8.8`, `1.1.1.1` o el de tu router), **no** `127.0.0.53`.

```bash
sudo ss -lntup | grep ':53 '
```

No debe aparecer `systemd-resolve`.

Por último, reinicia Docker para que tome el nuevo DNS:

```bash
sudo systemctl restart docker
```

<details>
<summary>Revertir (dejar Ubuntu como estaba al terminar la práctica)</summary>

```bash
sudo rm /etc/systemd/resolved.conf.d/disable-stub.conf
```

```bash
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
```

```bash
sudo systemctl restart systemd-resolved
```

</details>

## 2. Levantar la práctica

```bash
cd ~/ITQ-Admin_de_redes-Practicas/u3/p3-log
```

```bash
chmod 644 bind/*
```

```bash
docker compose up -d --build
```

```bash
docker compose ps
```

Los 6 contenedores (`dns`, `web`, `dhcp`, `ftp`, `pc1`, `pc2`) deben estar en `Up`.

## 3. Dar IP por DHCP a pc1 y pc2

```bash
docker exec pc1 bash -c "ip addr flush dev eth0 && dhclient -v eth0"
```

```bash
docker exec pc2 bash -c "ip addr flush dev eth0 && dhclient -v eth0"
```

Verifica que pc1 tiene `192.168.30.100` y que su DNS es `192.168.30.4`:

```bash
docker exec pc1 bash -c "hostname -I; cat /etc/resolv.conf"
```

> Si reinicias los contenedores, repite este paso: los pcs vuelven a la IP que les da Docker.

---

## Cómo entrar a un contenedor

Usa dos terminales: en una **entras al servidor** y sigues su log; en la otra **generas tráfico**
desde pc1/pc2.

```bash
docker exec -it web sh      # web usa Alpine: no tiene bash
```

```bash
docker exec -it dhcp bash   # también: dns, ftp, pc1, pc2
```

Para salir del contenedor escribe `exit`.

---

## Parte 1 – Logs HTTP (contenedor `web`)

**Terminal 1** – entra al servidor web y sigue sus logs:

```bash
docker exec -it web sh
```

```sh
cd /usr/local/apache2/logs
```

```sh
ls -l
```

```sh
tail -f access_log error_log
```

**Terminal 2** – genera peticiones:

```bash
docker exec pc1 curl -i -A "Mozilla/5.0 (PracticaRedes-PC1)" http://web.chema.osvp/
```

```bash
docker exec pc1 curl -i http://web.chema.osvp/no_existe.html
```

```bash
docker exec pc2 curl -i http://web.chema.osvp/secreto/privado.html
```

```bash
docker exec pc2 curl -i -X POST -d "usuario=chema&grupo=redes" http://web.chema.osvp/
```

Ejemplo de `access_log`:

```
192.168.30.100 - - [23/Nov/2026:17:28:03 +0000] "GET / HTTP/1.1" 200 42 "-" "Mozilla/5.0 (PracticaRedes-PC1)" rt=1009_us
192.168.30.100 - - [23/Nov/2026:17:28:03 +0000] "GET /no_existe.html HTTP/1.1" 404 236 "-" "curl/7.81.0" rt=351_us
192.168.30.101 - - [23/Nov/2026:17:28:03 +0000] "GET /secreto/privado.html HTTP/1.1" 403 239 "-" "curl/7.81.0" rt=277_us
192.168.30.101 - - [23/Nov/2026:17:28:03 +0000] "POST / HTTP/1.1" 200 42 "-" "curl/7.81.0" rt=219_us
```

Ejemplo de `error_log`:

```
[core:info] [client 192.168.30.100:39992] AH00128: File does not exist: /usr/local/apache2/htdocs/no_existe.html
[authz_core:error] [client 192.168.30.101:52648] AH01630: client denied by server configuration: /usr/local/apache2/htdocs/secreto/privado.html
```

| Qué identificar      | Dónde está                                                                  |
|----------------------|------------------------------------------------------------------------------|
| 200 OK               | `access_log`: `" 200 42`                                                     |
| 404 Not Found        | `access_log`: `" 404`  ·  `error_log`: `AH00128 File does not exist`         |
| 403 Forbidden        | `access_log`: `" 403`  ·  `error_log`: `AH01630 client denied`               |
| Método GET / POST    | `"GET /…"` / `"POST /…"`                                                     |
| IP de origen         | Primer campo de la línea (`192.168.30.100` = pc1, `.101` = pc2)             |
| User-Agent           | Último texto entre comillas: `"Mozilla/5.0 (PracticaRedes-PC1)"`, `"curl/7.81.0"` |
| Tiempo de respuesta  | `rt=…_us` al final (microsegundos)                                           |

## Parte 2 – Logs DNS (contenedor `dns`)

> **Nota:** la imagen `ubuntu/bind9` arranca BIND con `named -g`, que **ignora** el bloque
> `logging` de `named.conf.options` y envía todo a la salida del contenedor. Por eso el
> DNS no guarda un archivo de log dentro del contenedor: se consulta con `docker logs`.
> Dentro sí puedes revisar su configuración (`/etc/bind/`) y la zona (`/etc/bind/db.chema.osvp`).

**Terminal 1:**

```bash
docker logs -f dns
```

**Terminal 2:**

```bash
docker exec pc1 dig web.chema.osvp A
```

```bash
docker exec pc1 dig web.chema.osvp AAAA
```

```bash
docker exec pc1 dig www.chema.osvp CNAME
```

```bash
docker exec pc1 dig chema.osvp MX
```

```bash
docker exec pc1 dig google.com A
```

```bash
docker exec pc1 dig +norecurse web.chema.osvp A
```

```bash
docker exec pc1 dig servidor-fantasma.chema.osvp A
```

Ejemplo del log:

```
client @0x7fa6… 192.168.30.100#35683 (web.chema.osvp): query: web.chema.osvp IN AAAA +E(0)K (192.168.30.4)
client @0x7fa6… 192.168.30.100#42432 (chema.osvp): query: chema.osvp IN MX +E(0)K (192.168.30.4)
client @0x7fa6… 192.168.30.100#50493 (web.chema.osvp): query: web.chema.osvp IN A -E(0)K (192.168.30.4)
client @0x7fa6… 192.168.30.100#55062 (servidor-fantasma.chema.osvp): query: servidor-fantasma.chema.osvp IN A +E(0)K (192.168.30.4)
```

| Qué identificar           | Dónde está                                                                      |
|---------------------------|----------------------------------------------------------------------------------|
| Tipo de consulta          | `IN A`, `IN AAAA`, `IN MX`, `IN CNAME`                                          |
| Dominio consultado        | `(web.chema.osvp)` y después de `query:`                                        |
| Respuesta proporcionada   | El log del servidor solo guarda la pregunta; la respuesta está en `dig`: `ANSWER SECTION` y `status:` |
| Recursiva / no recursiva  | `+` = recursión solicitada · `-` = no recursiva (`dig +norecurse`)              |
| Error NXDOMAIN            | `dig` muestra `status: NXDOMAIN` para `servidor-fantasma.chema.osvp`            |
| Origen de la consulta     | `192.168.30.100#35683` = IP y puerto del cliente                                |

`AAAA` de `web.chema.osvp` responde `NOERROR` con `ANSWER: 0`: el nombre existe, pero no tiene IPv6.

## Parte 3 – Logs DHCP (contenedor `dhcp`)

`dhcpd` guarda las concesiones **dentro** del contenedor en `/data/dhcpd.leases`. Los mensajes
`DISCOVER/OFFER/REQUEST/ACK` no van a un archivo, porque el contenedor no tiene servidor syslog,
así que se ven con `docker logs dhcp`.

**Terminal 1** – mensajes del servidor:

```bash
docker logs -f dhcp
```

**Terminal 3 (opcional)** – entra y revisa las concesiones:

```bash
docker exec -it dhcp bash
```

```bash
cat /data/dhcpd.leases
```

**Terminal 2** – genera los eventos:

**a) Liberación (DHCPRELEASE):**

```bash
docker exec pc1 dhclient -r -v eth0
```

**b) Asignación completa (DISCOVER → OFFER → REQUEST → ACK):**

```bash
docker exec pc1 dhclient -v eth0
```

**c) Renovación** (pc2 vuelve a pedir la IP que ya tiene → solo REQUEST + ACK):

```bash
docker exec pc2 dhclient -v eth0
```

**d) Conflicto: IP ya en uso.** pc2 se asigna a mano una IP libre del rango (`.102`) y luego
llega un cliente nuevo: una interfaz virtual en pc1 con otra MAC. El servidor hace ping antes de
ofrecer la IP, alguien responde y la descarta.

```bash
docker exec pc2 ip addr add 192.168.30.102/24 dev eth0
```

```bash
docker exec pc1 bash -c "ip link add nuevo0 link eth0 type macvlan mode bridge && ip link set nuevo0 up && dhclient -v -1 -sf /bin/true -lf /tmp/nuevo.leases -pf /tmp/nuevo.pid nuevo0"
```

Limpieza:

```bash
docker exec pc1 bash -c "dhclient -x -sf /bin/true -pf /tmp/nuevo.pid; ip link del nuevo0"
```

```bash
docker exec pc2 ip addr del 192.168.30.102/24 dev eth0
```

> Si `.102` ya estaba concedida, usa la siguiente IP del rango que no aparezca en `/data/dhcpd.leases`.

**e) Conflicto: un cliente pide la IP de otro.** pc2 solicita `192.168.30.100`, que es de pc1,
y el servidor la rechaza con `DHCPNAK`. Con `-sf /bin/true`, pc2 no cambia su configuración.

```bash
docker exec pc2 bash -c 'printf "lease {\n  interface \"eth0\";\n  fixed-address 192.168.30.100;\n  expire 4 2030/01/01 00:00:00;\n}\n" > /tmp/c.leases && dhclient -v -1 -sf /bin/true -lf /tmp/c.leases -pf /tmp/c.pid eth0'
```

```bash
docker exec pc2 dhclient -x -sf /bin/true -pf /tmp/c.pid
```

**f) La concesión vista desde el cliente:**

```bash
docker exec -it pc1 bash
```

```bash
cat /var/lib/dhcp/dhclient.leases
```

Ejemplo de `docker logs dhcp`:

```
DHCPRELEASE of 192.168.30.100 from f6:fa:83:35:d1:32 (pc1) via eth0 (found)
DHCPDISCOVER from f6:fa:83:35:d1:32 (pc1) via eth0
DHCPOFFER on 192.168.30.100 to f6:fa:83:35:d1:32 (pc1) via eth0
DHCPREQUEST for 192.168.30.100 (192.168.30.254) from f6:fa:83:35:d1:32 (pc1) via eth0
DHCPACK on 192.168.30.100 to f6:fa:83:35:d1:32 (pc1) via eth0
DHCPREQUEST for 192.168.30.101 from 82:71:56:0a:13:ab (pc2) via eth0
DHCPACK on 192.168.30.101 to 82:71:56:0a:13:ab (pc2) via eth0
ICMP Echo reply while lease 192.168.30.102 valid.
Abandoning IP address 192.168.30.102: pinged before offer
DHCPREQUEST for 192.168.30.100 from 82:71:56:0a:13:ab via eth0: lease 192.168.30.100 unavailable.
DHCPNAK on 192.168.30.100 to 82:71:56:0a:13:ab via eth0
```

Ejemplo de `/data/dhcpd.leases`:

```
lease 192.168.30.100 {
  starts 1 2026/11/23 17:28:06;
  ends 1 2026/11/23 17:38:06;
  binding state active;
  hardware ethernet f6:fa:83:35:d1:32;
  client-hostname "pc1";
}
lease 192.168.30.102 {
  binding state abandoned;
}
```

| Qué identificar                   | Dónde está                                                                   |
|-----------------------------------|-------------------------------------------------------------------------------|
| DISCOVER / OFFER / REQUEST / ACK  | `docker logs dhcp`                                                            |
| MAC del cliente                   | `from f6:fa:83:35:d1:32 (pc1)` · `hardware ethernet` en `dhcpd.leases`       |
| IP asignada y tiempo de concesión | `DHCPACK on 192.168.30.100` · `starts`/`ends` (600 s = `default-lease-time`) · en el cliente: `dhcp-lease-time`, `renew`, `rebind`, `expire` |
| Renovación                        | `DHCPREQUEST` + `DHCPACK` **sin** `DHCPDISCOVER` antes                        |
| Liberación                        | `DHCPRELEASE of … (found)` → la IP pasa a `binding state free`                |
| Conflictos de IP                  | `Abandoning IP address … pinged before offer` / `binding state abandoned` / `lease … unavailable` + `DHCPNAK` |

## Extra – Logs FTP (contenedor `ftp`)

**Terminal 1:**

```bash
docker exec -it ftp bash
```

```bash
tail -f /var/log/vsftpd.log
```

**Terminal 2** – login correcto y login fallido:

```bash
docker exec pc1 bash -c 'ftp -inv ftp.chema.osvp <<EOF
user alumno osvp2026
ls
bye
EOF'
```

```bash
docker exec pc1 bash -c 'ftp -inv ftp.chema.osvp <<EOF
user alumno clave_incorrecta
bye
EOF'
```

```
[pid 19] CONNECT: Client "192.168.30.100"
[pid 18] [alumno] OK LOGIN: Client "192.168.30.100"
[pid 21] [alumno] FAIL LOGIN: Client "192.168.30.100"
```

## Apagar

```bash
docker compose down
```

Al bajar los contenedores se borran también sus logs.

---

## Errores comunes

### `lookup registry-1.docker.io on 127.0.0.53:53 … connection refused`

```
failed to resolve source metadata for docker.io/library/ubuntu:22.04 ...
dial tcp: lookup registry-1.docker.io on 127.0.0.53:53: read udp ...: connection refused
```

**Causa:** desactivaste el stub (`DNSStubListener=no`), pero `/etc/resolv.conf` sigue apuntando a
`127.0.0.53`, donde ya no escucha nadie. Al host (y a Docker) se le quedó sin DNS.

**Solución:** completa el paso 1 (sobre todo el `ln -sf` y el reinicio), revisa que
`cat /etc/resolv.conf` ya no diga `127.0.0.53` y reinicia Docker:

```bash
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
```

```bash
sudo systemctl restart systemd-resolved
```

```bash
sudo systemctl restart docker
```

Si `/etc/resolv.conf` queda **sin** ninguna línea `nameserver`, falta la línea `DNS=8.8.8.8 1.1.1.1`
en `/etc/systemd/resolved.conf.d/disable-stub.conf` (paso 1).

### Puerto ocupado: `Bind for 0.0.0.0:53 failed: port is already allocated` / `address already in use`

Otro programa usa el puerto. Revisa quién es:

```bash
sudo ss -lntup | grep -E ':(53|80|21) '
```

- **53** → `systemd-resolved`: haz el paso 1. Si es `named` o `dnsmasq` del host: `sudo systemctl stop named` / `sudo systemctl stop dnsmasq`.
- **80** → Apache o Nginx del host: `sudo systemctl stop apache2` / `sudo systemctl stop nginx`.
- **21** → vsftpd del host: `sudo systemctl stop vsftpd`.
- Un contenedor de otra práctica: ver el siguiente error.

### `The container name "/dns" is already in use` o `Pool overlaps with other one on this address space`

Los contenedores o la red de la práctica anterior (`u2`) siguen activos: usan los mismos
nombres (`dns`, `dhcp`, `pc1`, `pc2`) y la misma subred `192.168.30.0/24`. Bájalos:

```bash
cd ~/ITQ-Admin_de_redes-Practicas/u2/p2-dhcp && docker compose down
```

O elimínalos directamente:

```bash
docker rm -f dns dhcp web ftp pc1 pc2
```

```bash
docker network prune
```

### `429 Too Many Requests` al descargar imágenes

Docker Hub limita las descargas anónimas. Espera unos minutos e intenta otra vez, o inicia sesión:

```bash
docker login
```

### `permission denied while trying to connect to the Docker daemon socket`

Tu usuario no está en el grupo `docker`:

```bash
sudo usermod -aG docker $USER
```

Cierra sesión y vuelve a entrar (o ejecuta `newgrp docker`).

### `curl: (6) Could not resolve host: web.chema.osvp` en pc1/pc2

El pc no tiene la IP ni el DNS del DHCP: falta el paso 3 o reiniciaste los contenedores. Revisa:

```bash
docker exec pc1 cat /etc/resolv.conf
```

Debe decir `nameserver 192.168.30.4`. Si no, repite el paso 3.

### Un contenedor se reinicia una y otra vez (`Restarting` en `docker compose ps`)

Casi siempre es un error de sintaxis en su configuración. Revisa su salida:

```bash
docker logs dns
```

```bash
docker logs web
```

```bash
docker logs dhcp
```

- `dns`: revisa `bind/*.conf` y `bind/db.chema.osvp` (punto final en los nombres, paréntesis del SOA). Comprueba los permisos con `chmod 644 bind/*`.
- `web`: error en `apache/httpd.conf` (la línea aparece en el log).
- `dhcp`: error en `dhcpd.conf` (falta un `;` o una `}`).

### `dig google.com` no responde o da `SERVFAIL`

El contenedor `dns` reenvía a `8.8.8.8` y `1.1.1.1`. Si tu red bloquea ese tráfico DNS
(redes escolares o corporativas), la consulta externa falla. Las consultas a `chema.osvp`
siguen funcionando.

---

## Archivos de la práctica

```
p3-log/
├── .env
├── compose.yaml
├── Dockerfile.pc
├── dhcpd.conf
├── bind/
│   ├── named.conf.local
│   ├── named.conf.options
│   └── db.chema.osvp
└── apache/
    ├── httpd.conf          # logs en /usr/local/apache2/logs/ (dentro del contenedor)
    └── html/
        ├── index.html
        └── secreto/privado.html
```

**Ajustes respecto al documento original:**

- `apache/httpd.conf` guarda los logs dentro del contenedor (`logs/access_log`, `logs/error_log`).
  `LogLevel warn core:info` registra también los 404 en `error_log`.
- `Dockerfile.pc` permite que `dhclient` aplique el DNS recibido por DHCP dentro del contenedor,
  y añade `netbase`, que el cliente `ftp` necesita.
- `compose.yaml` (ftp): un `command` que también muestra `/var/log/vsftpd.log` en `docker logs ftp`.
