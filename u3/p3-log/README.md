# Práctica 03 – Logs de servicios (DNS, HTTP, DHCP, FTP)

Red `192.168.30.0/24` con 6 contenedores:

| Contenedor | Servicio            | IP                  |
|------------|---------------------|---------------------|
| `dns`      | BIND9 (querylog)    | 192.168.30.4        |
| `web`      | Apache `httpd`      | 192.168.30.5        |
| `ftp`      | vsftpd              | 192.168.30.6        |
| `dhcp`     | ISC DHCP            | 192.168.30.254      |
| `pc1`      | Cliente (DHCP)      | 192.168.30.100      |
| `pc2`      | Cliente (DHCP)      | 192.168.30.101      |

## Inicio rápido

```bash
cd u3/p3-log
chmod +x practica.sh
./practica.sh up        # construye, levanta y da IP por DHCP a pc1/pc2
```

Si el host usa `systemd-resolved` y el puerto 53 está ocupado, primero ejecuta:

```bash
./practica.sh liberar53
```

## Generar eventos y ver logs

Abre **dos terminales** en `u3/p3-log`:

| Terminal 1 (logs en vivo)   | Terminal 2 (generar eventos) | Qué se observa                                   |
|-----------------------------|------------------------------|--------------------------------------------------|
| `./practica.sh logs web`    | `./practica.sh http`         | IP origen, GET/POST, 200/404/403, User-Agent, `rt=..._us` |
| `./practica.sh logs dns`    | `./practica.sh dns`          | IP#puerto, dominio, tipo (A/CNAME/MX), `+` recursiva / `-` no recursiva, NXDOMAIN |
| `./practica.sh logs dhcp`   | `./practica.sh dhcp`         | DHCPRELEASE, DISCOVER/OFFER/REQUEST/ACK, MACs    |
| `./practica.sh logs ftp`    | `./practica.sh ftp`          | CONNECT, OK LOGIN, FAIL LOGIN                    |

Otros comandos:

```bash
./practica.sh todo      # ejecuta las 4 partes seguidas
./practica.sh leases    # concesiones DHCP activas (MAC, tiempos de lease)
./practica.sh dhcp-pcs  # volver a pedir IP por DHCP en pc1 y pc2
./practica.sh ps        # estado de los contenedores
./practica.sh down      # apagar y eliminar todo
```

Acceso SSH a los clientes (contraseña `osvp2026`): `ssh root@localhost -p 2223` (pc1) y `-p 2224` (pc2).

## Ajustes respecto al documento original

- **`Dockerfile.pc`**: dentro de un contenedor, `dhclient` no podía escribir el DNS
  recibido por DHCP en `/etc/resolv.conf` (hook de systemd-resolved + archivo montado
  por Docker). Sin esto, `pc1`/`pc2` no resuelven `*.chema.osvp`. También se agrega
  `netbase` (`/etc/services`), sin el cual el cliente `ftp` falla con
  *"Servname not supported"*.
- **`compose.yaml` (ftp)**: la imagen `fauria/vsftpd` envía la salida de vsftpd a
  `/dev/null`, por lo que `docker logs ftp` quedaba vacío. Se añade un `command`
  que muestra `/var/log/vsftpd.log` en la salida del contenedor.
