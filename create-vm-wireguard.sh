#!/usr/bin/env bash
#
# create-vm-wireguard.sh
# Script interactivo para Proxmox VE que crea una VM Ubuntu cloud, configura cloud-init
# y prepara Docker + wireguard-ui (o wg-easy) con docker-compose.
#
# Ejecutar en el host Proxmox como root.
#
set -euo pipefail

# ----------------------------------------------------------
# Helpers
# ----------------------------------------------------------
info()  { echo -e "\e[1;34m[INFO]\e[0m $*"; }
warn()  { echo -e "\e[1;33m[WARN]\e[0m $*"; }
error() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  error "Ejecuta este script como root en el host Proxmox."
fi

command -v qm >/dev/null 2>&1 || error "Este script requiere 'qm' (Proxmox QEMU)."

# Defaults
CLOUDIMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
TEMPLATE_DIR="/var/lib/vz/template/qemu"
SNIPPETS_DIR="/var/lib/vz/snippets"

read -rp "VM ID (ej. 200): " VMID
VMID=${VMID:-200}

read -rp "Nombre VM (ej. vpn-wg): " VM_NAME
VM_NAME=${VM_NAME:-vpn-wg}

read -rp "Almacenamiento destino (ej. local-lvm): " STORAGE
STORAGE=${STORAGE:-local-lvm}

read -rp "Bridge de red (ej. vmbr0): " BRIDGE
BRIDGE=${BRIDGE:-vmbr0}

read -rp "IP privada para la VM (CIDR) (ej. 192.168.1.50/24) [vacío para DHCP]: " IP_CIDR
read -rp "Gateway (ej. 192.168.1.1) [dejar vacío si DHCP]: " GATEWAY

read -rp "FQDN para WireGuard (ej. vpn.midominio.ddns.net) [opcional, usado en docker env]: " WG_FQDN
read -rp "¿Usar wireguard-ui o wg-easy? (ui/easy) [ui]: " WG_CHOICE
WG_CHOICE=${WG_CHOICE:-ui}

read -rp "¿Configurar SMTP para enviar configs por mail? (s/n) [n]: " USE_SMTP
USE_SMTP=${USE_SMTP:-n}

SMTP_HOST=""
SMTP_PORT=""
SMTP_USER=""
SMTP_PASS=""
SMTP_SENDER=""

if [[ "$USE_SMTP" =~ ^[sS] ]]; then
  read -rp "SMTP_HOST (ej. smtp.gmail.com): " SMTP_HOST
  read -rp "SMTP_PORT (ej. 587): " SMTP_PORT
  SMTP_PORT=${SMTP_PORT:-587}
  read -rp "SMTP_USERNAME (ej. tu@correo.com): " SMTP_USER
  read -rp "SMTP_PASSWORD (la contraseña o app-password): " SMTP_PASS
  read -rp "SMTP_SENDER (direccion desde la que se envían mails): " SMTP_SENDER
fi

read -rp "Número de CPUs [1]: " CPUS
CPUS=${CPUS:-1}
read -rp "Memoria en MB [1024]: " MEM
MEM=${MEM:-1024}
read -rp "Tamaño disco en GB [8]: " DISK_GB
DISK_GB=${DISK_GB:-8}

read -rp "Usuario SSH que usarás (key será añadida al usuario; por defecto 'ubuntu') [ubuntu]: " CI_USER
CI_USER=${CI_USER:-ubuntu}
read -rp "Pega aquí tu clave pública SSH (orja: ssh-rsa AAAA...): " SSH_KEY

# verify template dir exists
mkdir -p "$TEMPLATE_DIR"
mkdir -p "$SNIPPETS_DIR"

IMG_NAME=$(basename "$CLOUDIMG_URL")
IMG_PATH="$TEMPLATE_DIR/$IMG_NAME"

if [[ ! -f "$IMG_PATH" ]]; then
  info "Descargando imagen cloud de Ubuntu (esto puede tardar)..."
  wget -O "$IMG_PATH" "$CLOUDIMG_URL"
else
  info "Imagen cloud ya existe: $IMG_PATH"
fi

# Create VM
info "Creando VM ${VMID} (${VM_NAME})..."
qm create "$VMID" --name "$VM_NAME" --memory "$MEM" --cores "$CPUS" --net0 virtio,bridge="$BRIDGE" --ostype l26

info "Importando disco cloudimg a storage ${STORAGE}..."
qm importdisk "$VMID" "$IMG_PATH" "$STORAGE" --format qcow2

# Attach the imported disk as scsi0 and enable scsi controller
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 "$STORAGE":vm-"$VMID"-disk-0

# Add cloud-init disk and console config
qm set "$VMID" --ide2 "$STORAGE":cloudinit
qm set "$VMID" --boot order=scsi0
qm set "$VMID" --serial0 socket --vga serial0

# Networking: set ipconfig0 if user provided IP
if [[ -n "$IP_CIDR" ]]; then
  if [[ -n "$GATEWAY" ]]; then
    IPCFG="ip=${IP_CIDR},gw=${GATEWAY}"
  else
    IPCFG="ip=${IP_CIDR}"
  fi
  qm set "$VMID" --ipconfig0 "$IPCFG"
  info "Cloud-init configurado con IP: $IPCFG"
else
  info "No se configuró IP estática (se usará DHCP)"
fi

# Create cloud-init user-data snippet
SNIPPET_FILE="${SNIPPETS_DIR}/user-data-${VMID}"
info "Generando cloud-init user-data en ${SNIPPET_FILE} ..."

# Prepare docker-compose content based on choice
if [[ "$WG_CHOICE" == "easy" || "$WG_CHOICE" == "wg-easy" ]]; then
  COMPOSE_CONTENT=$(cat <<'EOF'
version: "3.8"
services:
  wg-easy:
    image: weejewel/wg-easy:latest
    container_name: wg-easy
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    environment:
      - WG_HOST=__WG_FQDN__
      - PASSWORD=changeme123
      - WG_PORT=51820
      - WG_DEFAULT_ADDRESS=10.13.13.1
      - WG_DEFAULT_DNS=1.1.1.1
    ports:
      - "51820:51820/udp"
      - "51821:51821/tcp"
    volumes:
      - ./data:/etc/wireguard
EOF
)
else
  # wireguard-ui
  COMPOSE_CONTENT=$(cat <<'EOF'
version: "3.8"
services:
  wireguard-ui:
    image: ngoduykhanh/wireguard-ui:latest
    container_name: wireguard-ui
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    environment:
      - WG_HOST=__WG_FQDN__
      - WG_PORT=51820
      - LISTEN_PORT=5000
      - TZ=UTC
      # SMTP placeholders (may be empty)
      - SMTP_HOST=__SMTP_HOST__
      - SMTP_PORT=__SMTP_PORT__
      - SMTP_USERNAME=__SMTP_USERNAME__
      - SMTP_PASSWORD=__SMTP_PASSWORD__
      - SMTP_SENDER=__SMTP_SENDER__
    ports:
      - "51820:51820/udp"
      - "127.0.0.1:5000:5000/tcp"
    volumes:
      - ./wireguard:/etc/wireguard
EOF
)
fi

# Replace placeholders
COMPOSE_CONTENT=${COMPOSE_CONTENT//__WG_FQDN__/${WG_FQDN:-}}
COMPOSE_CONTENT=${COMPOSE_CONTENT//__SMTP_HOST__/${SMTP_HOST:-}}
COMPOSE_CONTENT=${COMPOSE_CONTENT//__SMTP_PORT__/${SMTP_PORT:-}}
COMPOSE_CONTENT=${COMPOSE_CONTENT//__SMTP_USERNAME__/${SMTP_USER:-}}
COMPOSE_CONTENT=${COMPOSE_CONTENT//__SMTP_PASSWORD__/${SMTP_PASS:-}}
COMPOSE_CONTENT=${COMPOSE_CONTENT//__SMTP_SENDER__/${SMTP_SENDER:-}}

# Generate the user-data cloud-init YAML
cat > "$SNIPPET_FILE" <<EOF
#cloud-config
preserve_hostname: false
hostname: ${VM_NAME}
manage_etc_hosts: true

users:
  - name: ${CI_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_KEY}

package_update: true
package_upgrade: true
packages:
  - curl
  - apt-transport-https
  - ca-certificates
  - software-properties-common
  - gnupg

runcmd:
  - [ bash, -lc, "set -e" ]
  - [ bash, -lc, "echo 'Instalando Docker (get.docker.com)...'"]
  - [ bash, -lc, "curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh" ]
  - [ bash, -lc, "apt-get update && apt-get install -y docker-compose-plugin" ]
  - [ bash, -lc, "mkdir -p /root/wg && cat > /root/wg/docker-compose.yml <<'DOCK'\n${COMPOSE_CONTENT}\nDOCK" ]
  - [ bash, -lc, "chown -R ${CI_USER}:${CI_USER} /root/wg" ]
  - [ bash, -lc, "docker compose -f /root/wg/docker-compose.yml up -d" ]
  - [ bash, -lc, "echo 'Instalación completada. Revisa los logs de cloud-init y docker compose.' > /var/log/wg-setup.log" ]

EOF

# Register snippet with the VM
info "Asignando snippet cloud-init a la VM..."
qm set "$VMID" --cicustom "user=local:snippets/user-data-${VMID}"

# Set cloud-init user if not default 'ubuntu'
qm set "$VMID" --ciuser "$CI_USER"

# If user wants to set password for CI user (optional)
read -rp "¿Quieres establecer una contraseña para el usuario ${CI_USER}? (s/n) [n]: " SET_PASS
if [[ "$SET_PASS" =~ ^[sS] ]]; then
  read -rsp "Contraseña: " CI_PASS; echo
  qm set "$VMID" --cipassword "$CI_PASS"
fi

info "VM creada. Arrancando VM ${VMID}..."
qm start "$VMID"

echo
info "Hecho. VM ${VMID} (${VM_NAME}) arrancada."
echo
echo "Siguientes pasos recomendados:"
echo "- Espera 1-2 minutos a que la VM termine el cloud-init y arranque los containers."
echo "- Entra a la VM con: qm terminal ${VMID}  (o por SSH con ${CI_USER}@${IP_CIDR%%/*} si usaste IP estática)"
echo "- Comprueba que Docker y el container están arriba:"
echo "    qm terminal ${VMID} -> sudo docker ps"
echo "- Si expusiste wireguard-ui en localhost:5000 dentro de la VM, configura tu nginx (máquina pública) como reverse-proxy hacia http://<IP_VM>:5000 y asegúrate de que el puerto UDP 51820 esté dirigido hacia la IP de la VM."
echo
echo "Recordatorio NAT/iptables (ejemplo si nginx-host tiene IP pública y debe reenviar UDP 51820 a la VM):"
echo "  sudo sysctl -w net.ipv4.ip_forward=1"
echo "  sudo iptables -t nat -A PREROUTING -p udp --dport 51820 -j DNAT --to-destination <IP_VM>:51820"
echo "  sudo iptables -A FORWARD -p udp -d <IP_VM> --dport 51820 -j ACCEPT"
echo
info "Si quieres, puedo generar también el archivo nginx para el reverse-proxy o adaptar la configuración del docker-compose (por ejemplo para cambiar puertos o agregar auth básica)."
