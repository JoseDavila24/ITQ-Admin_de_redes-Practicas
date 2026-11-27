# Práctica U3-P1: Análisis de logs HTTP, DNS y DHCP

```bash
docker compose up -d --build
```

> Sustituye `<IP_UBUNTU>` por la IP del servidor Ubuntu (`hostname -I`).
>
> `chema.osvp` apunta automáticamente a la IP de tu Ubuntu (se ve en `docker logs dns-server`). El dominio y la IP se pueden cambiar en `.env`. Si DHCP le cambia la IP a Ubuntu, ejecuta `docker compose restart dns-server`.

---

## Parte 1: HTTP (desde otra máquina)

```bash
# 200 OK - GET
curl -i http://<IP_UBUNTU>/

# 200 OK - POST (envío de formulario)
curl -i -X POST -d "dato=prueba" http://<IP_UBUNTU>/

# 404 Not Found
curl -i http://<IP_UBUNTU>/noexiste

# 403 Forbidden - directorio protegido
curl -i http://<IP_UBUNTU>/privado/

# 403 Forbidden - archivo .htaccess
curl -i http://<IP_UBUNTU>/.htaccess

# User-Agent distinto
curl -i -A "Mozilla/5.0 (X11; Fedora; Linux x86_64) Firefox/133.0" http://<IP_UBUNTU>/
```

También puedes abrir `http://<IP_UBUNTU>/` en un navegador y enviar el formulario.

### Logs

| Log | Ruta en el contenedor `web-server` |
| :--- | :--- |
| Accesos | `/usr/local/apache2/logs/access.log` |
| Errores | `/usr/local/apache2/logs/error.log` |

```bash
docker exec -it web-server cat /usr/local/apache2/logs/access.log
```

```bash
docker exec -it web-server cat /usr/local/apache2/logs/error.log
```

```bash
docker exec -it web-server tail -f /usr/local/apache2/logs/access.log
```

Formato de cada línea (el último campo es el tiempo de respuesta en microsegundos):

```
IP_ORIGEN - - [FECHA] "MÉTODO /ruta HTTP/1.1" CÓDIGO BYTES "Referer" "User-Agent" TIEMPO_µs
```

---

## Parte 2: DNS (desde otra máquina)

```bash
# A - dominio local (respuesta de config, no recursiva) -> devuelve <IP_UBUNTU>
dig A chema.osvp @<IP_UBUNTU>

# AAAA - recursiva (forwarded)
dig AAAA google.com @<IP_UBUNTU>

# MX - recursiva
dig MX gmail.com @<IP_UBUNTU>

# CNAME - recursiva
dig CNAME www.google.com @<IP_UBUNTU>

# Repetir: la segunda sale de caché (cached)
dig A google.com @<IP_UBUNTU>
dig A google.com @<IP_UBUNTU>

# No recursiva explícita
dig A google.com @<IP_UBUNTU> +norecurse

# NXDOMAIN
dig A dominio-falso-99999.com @<IP_UBUNTU>
```

### Logs

| Log | Ruta en el contenedor `dns-server` |
| :--- | :--- |
| Consultas DNS | `/var/log/dnsmasq.log` |

```bash
docker exec -it dns-server cat /var/log/dnsmasq.log
```

```bash
docker exec -it dns-server tail -f /var/log/dnsmasq.log
```

```bash
docker exec -it dns-server grep NXDOMAIN /var/log/dnsmasq.log
```

En el log: `query[TIPO]` (tipo y dominio), `from <IP>` (origen), `forwarded` (recursiva), `cached` / `config` (no recursiva), `reply ... is <valor>` (respuesta), `reply ... is NXDOMAIN` (error).

### HTTP por nombre: `http://chema.osvp` (desde Fedora)

Haz que Fedora use tu dnsmasq como DNS (temporal). Cambia `<interfaz>` por la de Fedora, que ves con `ip a` (por ejemplo `enp1s0`):

```bash
sudo resolvectl dns <interfaz> <IP_UBUNTU>
```

> Fedora enviará **todas** sus consultas a tu dnsmasq. Internet sigue funcionando, porque dnsmasq reenvía lo externo a 8.8.8.8, pero en el log también verás las consultas que Fedora hace en segundo plano.

```bash
curl -i http://chema.osvp/
curl -i http://chema.osvp/privado/
```

También funciona en el navegador de Fedora: `http://chema.osvp`.

Una sola petición deja rastro en los dos logs:

- `/var/log/dnsmasq.log` → `query[A] chema.osvp from <IP_FEDORA>` y `config chema.osvp is <IP_UBUNTU>`
- `/usr/local/apache2/logs/access.log` → `"GET / HTTP/1.1" 200 ...`

Para dejar el DNS de Fedora como estaba:

```bash
sudo resolvectl revert <interfaz>
```

---

## Parte 3: DHCP (desde el mismo Ubuntu, red aislada)

Las PCs `pc1` y `pc2` están en la red aislada `red-dhcp` (192.168.50.0/24) junto con `kea-server` (192.168.50.2). Los comandos se ejecutan en Ubuntu.

```bash
# Asignación inicial (DISCOVER, OFFER, REQUEST, ACK)
docker exec -it pc1 bash -c "ip addr flush dev eth0 && dhclient -v eth0"
docker exec -it pc2 bash -c "ip addr flush dev eth0 && dhclient -v eth0"

# Ver la IP asignada
docker exec -it pc1 ip a show eth0

# Renovación
docker exec -it pc1 dhclient -v -1 eth0

# Conflicto (NAK): pc2 pide la IP de pc1 (ajusta la IP); Ctrl+C para cortar
docker exec -it pc2 bash -c 'dhclient -r eth0; ip addr flush dev eth0; echo "send dhcp-requested-address 192.168.50.10;" > /etc/dhcp/dhclient.conf; dhclient -v eth0'

# Dejar pc2 normal otra vez
docker exec -it pc2 bash -c 'echo "" > /etc/dhcp/dhclient.conf'
docker exec -it pc2 bash -c "ip addr flush dev eth0 && dhclient -v eth0"

# Liberación (RELEASE)
docker exec -it pc1 dhclient -r -v eth0
```

### Logs

| Log | Ruta en el contenedor `kea-server` |
| :--- | :--- |
| Eventos DHCP | `/var/log/kea/kea-dhcp4.log` |
| Concesiones | `/var/lib/kea/kea-leases4.csv` |

```bash
docker exec -it kea-server cat /var/log/kea/kea-dhcp4.log
```

```bash
docker exec -it kea-server tail -f /var/log/kea/kea-dhcp4.log
```

```bash
docker exec -it kea-server grep -E "DHCPDISCOVER|DHCPOFFER|DHCPREQUEST|DHCPACK|DHCPNAK|DHCPRELEASE|DHCP4_LEASE_ALLOC|DHCP4_LEASE_REUSE|DHCP4_RELEASE" /var/log/kea/kea-dhcp4.log
```

```bash
docker exec -it kea-server cat /var/lib/kea/kea-leases4.csv
```

En el log: `[hwtype=1 <MAC>]` (MAC del cliente), `DHCP4_LEASE_ALLOC ... lease <IP> has been allocated for 120 seconds` (IP y tiempo de concesión), `DHCP4_LEASE_REUSE` (renovación), `DHCP4_RELEASE` (liberación), `DHCPNAK (type 6)` (conflicto).

> Para Wireshark, el tráfico DHCP pasa por la interfaz `br-dhcp` de Ubuntu (por ejemplo, `sudo tcpdump -i br-dhcp -w ~/dhcp.pcap 'port 67 or port 68'`).

---

## Detener

```bash
docker compose down
```
