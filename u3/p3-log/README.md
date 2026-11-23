# Práctica 03 – Análisis de logs (HTTP, DNS, DHCP)

**Objetivo:** analizar los archivos de registro de servicios de red en contenedores,
identificando patrones, errores y eventos que permitan diagnosticar su funcionamiento.

| Contenedor | Servicio         | IP              | ¿Dónde está su log?                                           |
|------------|------------------|-----------------|----------------------------------------------------------------|
| `web`      | Apache `httpd`   | 192.168.30.5    | **Dentro:** `/usr/local/apache2/logs/access_log` y `error_log` |
| `dns`      | BIND9            | 192.168.30.4    | `docker logs dns` (ver nota)                                   |
| `dhcp`     | ISC DHCP         | 192.168.30.254  | **Dentro:** `/data/dhcpd.leases` + mensajes en `docker logs dhcp` |
| `ftp`      | vsftpd           | 192.168.30.6    | **Dentro:** `/var/log/vsftpd.log`                              |
| `pc1/pc2`  | Clientes DHCP    | .100 / .101     | **Dentro:** `/var/lib/dhcp/dhclient.leases`                    |

> **Nota DNS:** la imagen `ubuntu/bind9` arranca `named -g`, que ignora el bloque
> `logging` y envía todo a stderr; por eso el querylog se consulta con `docker logs dns`.
> **Nota DHCP:** `dhcpd` registra por syslog y el contenedor no tiene servidor syslog, así que
> los mensajes DISCOVER/OFFER/… van a `docker logs dhcp`; dentro del contenedor queda el
> archivo de concesiones `/data/dhcpd.leases`.

## Inicio rápido

```bash
cd u3/p3-log
./practica.sh up          # construye, levanta y da IP por DHCP a pc1/pc2
```

Si el puerto 53 del host está ocupado (`systemd-resolved`): `./practica.sh liberar53` y repite `up`.

Cada parte genera los eventos **y después muestra el log del servicio**:

```bash
./practica.sh http        # Parte 1
./practica.sh dns         # Parte 2
./practica.sh dhcp        # Parte 3
./practica.sh ftp         # Extra
./practica.sh todo        # las 4 seguidas
```

Para observar en vivo en otra terminal: `./practica.sh ver web|dns|dhcp|leases|ftp`.
Para revisar a mano dentro de un contenedor: `./practica.sh entrar web` (luego `cat logs/access_log`).
Concesiones del servidor y de los clientes: `./practica.sh leases`.

---

## Parte 1 – Logs HTTP

```bash
docker exec web cat /usr/local/apache2/logs/access_log
docker exec web cat /usr/local/apache2/logs/error_log
```

Ejemplo real (`access_log`, formato `detallado` definido en `apache/httpd.conf`):

```
192.168.30.100 - - [23/Nov/2026:17:28:03 +0000] "GET / HTTP/1.1" 200 42 "-" "Mozilla/5.0 (PracticaRedes-PC1)" rt=1009_us
192.168.30.100 - - [23/Nov/2026:17:28:03 +0000] "GET /no_existe.html HTTP/1.1" 404 236 "-" "curl/7.81.0" rt=351_us
192.168.30.101 - - [23/Nov/2026:17:28:03 +0000] "GET /secreto/privado.html HTTP/1.1" 403 239 "-" "curl/7.81.0" rt=277_us
192.168.30.101 - - [23/Nov/2026:17:28:03 +0000] "POST / HTTP/1.1" 200 42 "-" "curl/7.81.0" rt=219_us
```

| Elemento a identificar   | Dónde aparece                                                        |
|--------------------------|----------------------------------------------------------------------|
| 200 OK                   | Campo tras la petición: `" 200 42`                                   |
| 404 Not Found            | `" 404 236` + en `error_log`: `AH00128: File does not exist`         |
| 403 Forbidden            | `" 403 239` + en `error_log`: `AH01630: client denied by server configuration` |
| Método GET / POST        | Inicio de la petición: `"GET /…` / `"POST /…`                        |
| IP de origen             | Primer campo: `192.168.30.100` (pc1) / `192.168.30.101` (pc2)       |
| User-Agent               | Último campo entre comillas: `"Mozilla/5.0 (PracticaRedes-PC1)"`, `"curl/7.81.0"` |
| Tiempo de respuesta      | `rt=…_us` (`%D`, microsegundos)                                      |

## Parte 2 – Logs DNS

```bash
docker logs dns 2>&1 | grep query
```

Ejemplo real:

```
client @0x7fa6… 192.168.30.100#35683 (web.chema.osvp): query: web.chema.osvp IN AAAA +E(0)K (192.168.30.4)
client @0x7fa6… 192.168.30.100#34764 (www.chema.osvp): query: www.chema.osvp IN CNAME +E(0)K (192.168.30.4)
client @0x7fa6… 192.168.30.100#42432 (chema.osvp): query: chema.osvp IN MX +E(0)K (192.168.30.4)
client @0x7fa6… 192.168.30.100#50493 (web.chema.osvp): query: web.chema.osvp IN A -E(0)K (192.168.30.4)
client @0x7fa6… 192.168.30.100#55062 (servidor-fantasma.chema.osvp): query: servidor-fantasma.chema.osvp IN A +E(0)K (192.168.30.4)
```

| Elemento a identificar     | Dónde aparece                                                                 |
|----------------------------|-------------------------------------------------------------------------------|
| Tipo de consulta           | `IN A`, `IN AAAA`, `IN MX`, `IN CNAME`                                        |
| Dominio consultado         | `(web.chema.osvp)` y tras `query:`                                            |
| Respuesta proporcionada    | El querylog solo guarda la pregunta; la respuesta se ve en `dig` (sección ANSWER y `status:`) |
| Recursiva vs no recursiva  | Bandera `+` = recursión solicitada; `-` = no recursiva (`dig +norecurse`)     |
| Error NXDOMAIN             | `dig` muestra `status: NXDOMAIN`; en el log aparece la consulta a `servidor-fantasma…` |
| Origen de la consulta      | `192.168.30.100#35683` → IP y puerto del cliente                              |
| Otros errores              | `query failed (…) for google.com/IN/A`: fallo de resolución externa           |

La consulta `AAAA` de `web.chema.osvp` responde `NOERROR` sin respuestas (`ANSWER: 0`):
el nombre existe, pero no tiene registro IPv6.

## Parte 3 – Logs DHCP

```bash
docker logs dhcp                                 # mensajes del servidor
docker exec dhcp cat /data/dhcpd.leases          # concesiones (dentro del contenedor)
docker exec pc1 cat /var/lib/dhcp/dhclient.leases  # concesión vista por el cliente
```

El script `./practica.sh dhcp` provoca estos eventos:

1. **Liberación:** `dhclient -r` en pc1 → `DHCPRELEASE of 192.168.30.100 from <MAC> (pc1)`
2. **Asignación (DORA):** `DHCPDISCOVER` → `DHCPOFFER on .100` → `DHCPREQUEST` → `DHCPACK`
3. **Renovación:** pc2 vuelve a pedir su IP → solo `DHCPREQUEST for 192.168.30.101` + `DHCPACK` (sin DISCOVER)
4. **Conflicto A (IP ya en uso):** pc2 se pone a mano la siguiente IP libre y llega un cliente nuevo.
   El servidor hace *ping* antes de ofrecer, alguien responde y descarta la IP:
   ```
   ICMP Echo reply while lease 192.168.30.102 valid.
   Abandoning IP address 192.168.30.102: pinged before offer
   DHCPOFFER on 192.168.30.103 to a6:0e:fa:80:27:c9 …
   ```
   En `dhcpd.leases` la IP queda con `binding state abandoned;`.
5. **Conflicto B (IP de otro equipo):** pc2 solicita la IP de pc1:
   ```
   DHCPREQUEST for 192.168.30.100 from f6:2c:ff:f7:8f:81 via eth0: lease 192.168.30.100 unavailable.
   DHCPNAK on 192.168.30.100 to f6:2c:ff:f7:8f:81 via eth0
   ```

Ejemplo de `/data/dhcpd.leases`:

```
lease 192.168.30.100 {
  starts 1 2026/11/23 17:28:06;
  ends 1 2026/11/23 17:38:06;
  binding state active;
  hardware ethernet 0e:a8:07:99:97:62;
  client-hostname "pc1";
}
```

| Elemento a identificar             | Dónde aparece                                                               |
|------------------------------------|-----------------------------------------------------------------------------|
| DISCOVER / OFFER / REQUEST / ACK   | `docker logs dhcp`                                                          |
| MAC del cliente                    | `from 0e:a8:07:99:97:62 (pc1)` y `hardware ethernet` en `dhcpd.leases`     |
| IP asignada y tiempo de concesión  | `DHCPACK on 192.168.30.100`; `starts`/`ends` (10 min = `default-lease-time 600`); en el cliente `dhcp-lease-time 600`, `renew`, `rebind`, `expire` |
| Renovaciones                       | `DHCPREQUEST` + `DHCPACK` sin `DHCPDISCOVER` previo                         |
| Liberaciones                       | `DHCPRELEASE of … (found)`; la IP pasa a `binding state free`               |
| Conflictos de IP                   | `Abandoning IP address …: pinged before offer`, `binding state abandoned`, `lease … unavailable` + `DHCPNAK` |

## Extra – FTP

```bash
docker exec ftp cat /var/log/vsftpd.log
```

```
[pid 19] CONNECT: Client "192.168.30.100"
[pid 18] [alumno] OK LOGIN: Client "192.168.30.100"
[pid 21] [alumno] FAIL LOGIN: Client "192.168.30.100"
```

---

## Ajustes respecto al documento original

- **`apache/httpd.conf`:** los logs se guardan dentro del contenedor (`logs/access_log`,
  `logs/error_log`) en lugar de `/proc/self/fd/*`. Además, `LogLevel warn core:info` hace
  que los 404 también aparezcan en `error_log`.
- **`Dockerfile.pc`:** permite que `dhclient` aplique el DNS recibido por DHCP dentro del
  contenedor y añade `netbase`, que necesita el cliente `ftp`.
- **`compose.yaml` (ftp):** `command` que muestra `/var/log/vsftpd.log` también en `docker logs ftp`.
