# proxmox-vm-wg-installer

Script para Proxmox que crea una VM Ubuntu (cloud image), la configura con cloud-init y prepara Docker + WireGuard UI (wireguard-ui o wg-easy) en un docker-compose. El script es interactivo y te pregunta los datos necesarios (VMID, nombre, IP, FQDN, SMTP opcional, etc).

Funciona ejecutándolo en el host Proxmox como root. El script usa las herramientas `qm` y `pct`/`pvesh` típicas de Proxmox.

Qué hace:
- Descarga la imagen cloud de Ubuntu 22.04 si no está ya en /var/lib/vz/template/qemu/
- Crea la VM con los parámetros que indiques (ID, memoria, núcleos, almacenamiento, bridge, tamaño de disco)
- Importa el disco cloudimg y configura cloud-init (user-data) para:
  - crear el usuario `ubuntu` (o usar la clave SSH que desees)
  - instalar Docker y docker-compose (plugin)
  - volcar un `docker-compose.yml` para wireguard-ui o wg-easy
  - arrancar el docker-compose en el primer boot
- Inicia la VM

Antes de ejecutar:
- Verifica que `qm` está instalado y que tienes acceso root en el host Proxmox.
- Si usas DynDNS/FQDN, asegúrate de que el FQDN apunte a tu IP pública para que los clientes WireGuard puedan usarlo como endpoint.
- La instalación de WireGuard dentro del contenedor Docker requerirá permisos `NET_ADMIN` (el compose lo incluye). La VM usa su propio kernel, por lo que no hay dependencia del host Proxmox en este aspecto.

Limitaciones / notas:
- El script crea un cloud-init "snippet" (`/var/lib/vz/snippets/user-data-<VMID>`) y lo asigna a la VM.
- El script configura la red del cloud-init usando `ip=` en `qm set --ipconfig0`. Si tu red requiere DHCP, deja vacío el campo IP en el prompt.
- No toca la máquina nginx que ya tienes; tendrás que configurar allí el reverse-proxy / DNAT para UDP 51820 hacia la VM (si tu nginx es el gateway) — el script recuerda esto al final.
- Si quieres HTTPS para la UI, usa tu nginx para proxear la UI y obtener certificados con certbot (ya lo hablamos antes).

---

## Cómo se instala (instrucciones)

Sigue estos pasos recomendados para instalar de forma segura el instalador y crear la VM en Proxmox.

1) Descarga y revisa (forma segura — recomendado)

- Descargar el script a tu máquina y revisarlo antes de ejecutar:

  curl -fsSL -o create-vm-wireguard.sh https://raw.githubusercontent.com/matatunos/Wireguard_ui_proxmox_installer/main/create-vm-wireguard.sh
  less create-vm-wireguard.sh

- Comprobar checksum (si publicas/consigues el SHA256 desde el repo):

  sha256sum create-vm-wireguard.sh

- Ejecutar solo tras revisarlo:

  chmod +x create-vm-wireguard.sh
  sudo ./create-vm-wireguard.sh

2) One-liner (NO recomendado sin inspección)

- Si confías en el contenido y quieres el método rápido:

  sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/matatunos/Wireguard_ui_proxmox_installer/main/create-vm-wireguard.sh)"

  Nota: es más seguro descargar y revisar el script antes de ejecutarlo.

3) Opción usando git (recomendada si vas a mantener una copia local)

  git clone https://github.com/matatunos/Wireguard_ui_proxmox_installer.git
  cd Wireguard_ui_proxmox_installer
  less create-vm-wireguard.sh   # revisa el contenido
  sha256sum create-vm-wireguard.sh
  sudo bash create-vm-wireguard.sh

4) Prerrequisitos

- Ejecutar como root (o usar sudo cuando se indique).
- Proxmox VE instalado y accesible.
- Comando `qm` disponible en el host Proxmox.
- Espacio de almacenamiento suficiente y conexión a Internet para descargar la imagen cloud.

5) Red / NAT / Reverse proxy (recordatorio)

- Asegúrate de que el puerto UDP 51820 (WireGuard) llegue a la VM: crea el DNAT/port-forward correspondiente en el router o en tu máquina pública.
- La UI web se sirve por defecto en el contenedor en el puerto 5000 (wireguard-ui) y está mapeada a localhost en la VM. Usa tu nginx público como reverse-proxy para exponerla con HTTPS.

Fragmento de ejemplo nginx (proxy + Let's Encrypt):

    server {
        listen 80;
        server_name TU_FQDN;
        location /.well-known/acme-challenge/ { root /var/www/certbot; }
        location / { return 301 https://$host$request_uri; }
    }

    server {
        listen 443 ssl;
        server_name TU_FQDN;

        ssl_certificate /etc/letsencrypt/live/TU_FQDN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/TU_FQDN/privkey.pem;
        include /etc/letsencrypt/options-ssl-nginx.conf;

        location / {
            proxy_pass http://IP_VM:5000/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }

6) Comandos útiles para verificar la URL RAW

- Ver el encabezado HTTP del raw URL:

  curl -I https://raw.githubusercontent.com/matatunos/Wireguard_ui_proxmox_installer/main/create-vm-wireguard.sh

- Descargar y abrir para revisión:

  curl -fsSL -o create-vm-wireguard.sh https://raw.githubusercontent.com/matatunos/Wireguard_ui_proxmox_installer/main/create-vm-wireguard.sh && less create-vm-wireguard.sh

7) Buenas prácticas de seguridad

- Nunca ejecutes un script `curl | bash` sin revisarlo.
- Comprueba la integridad mediante SHA256 o firmas si se publican.
- Mantén tu Proxmox y el host actualizados.
- Limita la exposición de la UI con autenticación básica o accésala solo por VPN/SSH-tunnel si es posible.
- Haz backups del volumen donde se almacenarían las claves de WireGuard (./wireguard en el contenedor).
- Usa puertos no estándar si tu ISP bloquea los puertos habituales.

---

Descargo de responsabilidad:
Este software se proporciona "tal cual", sin garantías de ningún tipo, ni expresas ni implícitas, incluidas, entre otras, garantías de comerciabilidad, idoneidad para un propósito particular y no infracción. El autor no será responsable de ningún daño directo, indirecto, incidental, especial, ejemplar o consecuente que surja del uso de este software.

Licencia: GPL-3.0
