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

Uso rápido (en Proxmox host, como root):
1. Copia `create-vm-wireguard.sh` al host (por ejemplo `/root/create-vm-wireguard.sh`) y dale permisos de ejecución:
   sudo chmod +x /root/create-vm-wireguard.sh
2. Ejecuta:
   sudo /root/create-vm-wireguard.sh
3. Sigue las preguntas en pantalla.

Descargo de responsabilidad:
Este software se proporciona "tal cual", sin garantías de ningún tipo, ni expresas ni implícitas, incluidas, entre otras, garantías de comerciabilidad, idoneidad para un propósito particular y no infracción. El autor no será responsable de ningún daño directo, indirecto, incidental, especial, ejemplar o consecuente (incluyendo, entre otros, la adquisición de bienes o servicios sustitutos; pérdida de uso, datos o beneficios; o interrupción de la actividad empresarial) que surja de cualquier manera del uso de este software, incluso si se ha advertido de la posibilidad de tales daños.

Licencia:
Este proyecto se publica bajo la licencia GNU General Public License v3.0 (GPL-3.0). Consulta el archivo LICENSE para el texto completo.

Contribuciones y mejoras:
Si quieres que adapte el script (por ejemplo, usar Ubuntu 24.04, cambiar el usuario, agregar opciones avanzadas de disco o red), abre un issue o PR en este repositorio.
