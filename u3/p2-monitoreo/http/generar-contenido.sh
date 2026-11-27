#!/bin/sh
# Crea contenido de distintos tipos y tamaños junto a la página por defecto
# ("It works!") para comparar tiempos de respuesta. No se guarda nada en el repo.
set -e
cd /usr/local/apache2/htdocs

# text/plain (~30 bytes)
echo "Hola, esto es texto plano." > texto.txt

# application/json (~60 bytes)
echo '{"practica": "p2-monitoreo", "protocolo": "HTTP", "ok": true}' > datos.json

# image/png (~9 KB): icono que ya trae Apache
cp /usr/local/apache2/icons/apache_pb.png imagen.png

# application/octet-stream (10 MB)
[ -f grande.bin ] || dd if=/dev/urandom of=grande.bin bs=1M count=10 2>/dev/null

# Directorio: pedir /carpeta (sin "/") devuelve 301 Moved Permanently
mkdir -p carpeta
echo "<html><body><h1>Carpeta</h1></body></html>" > carpeta/index.html

ls -l /usr/local/apache2/htdocs
exec httpd-foreground
