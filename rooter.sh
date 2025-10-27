#!/bin/bash
# /usr/local/bin/router.sh
# Script interactif pour transformer une interface Ethernet en point relais Wi-Fi
# Usage:
#   sudo /usr/local/bin/router.sh start
#   sudo /usr/local/bin/router.sh stop
#   sudo /usr/local/bin/router.sh status
#   sudo /usr/local/bin/router.sh interactive   # pose les questions
#
# Il crée/écrase /etc/hostapd/hostapd.conf (sauvegarde si existant)
# et /etc/dnsmasq.d/router.conf (sauvegarde si existant).

set -u

# --- CONFIG PAR DÉFAUT (modifiable) ---
DEFAULT_WIFI_IP="192.168.50.1/24"
DEFAULT_DHCP_START="192.168.50.10"
DEFAULT_DHCP_END="192.168.50.50"
DEFAULT_SSID="MonWifi"
DEFAULT_PSK="ChangeMe1234"
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
DNSMASQ_CONF="/etc/dnsmasq.d/router.conf"

# --- Fonctions utilitaires ---
log() { echo -e "\e[1;32m[router]\e[0m $*"; }
warn() { echo -e "\e[1;33m[router]\e[0m $*"; }
err() { echo -e "\e[1;31m[router]\e[0m $*" >&2; }

confirm() {
  read -r -p "$1 [o/N] " ans
  case "$ans" in
    o|O|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

# Check si règle iptables existe (compatible avec anciennes versions)
iptables_has_rule() {
  # arguments after -C may vary per iptables version; fallback to grep if -C fails
  if iptables -C "$@" 2>/dev/null; then
    return 0
  else
    # fallback: list rules and grep (less safe but works)
    if iptables -S | grep -F -- "$(echo "$@" | sed 's/^-A /-A /')" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
}

# --- Récupération / demande des interfaces (interactive si besoin) ---
get_interfaces_interactive() {
  read -r -p "Interface Internet (carte principale, ex. enx...): " ETH_IF
  read -r -p "Interface Wi-Fi à utiliser comme AP (ex. wlp1s0): " WIFI_IF
  read -r -p "SSID (nom du réseau) [${DEFAULT_SSID}]: " tmp
  SSID="${tmp:-$DEFAULT_SSID}"
  read -r -p "Mot de passe WPA2 (min 8 chars) [${DEFAULT_PSK}]: " tmp
  PSK="${tmp:-$DEFAULT_PSK}"
  read -r -p "IP du point d'accès (passerelle) [${DEFAULT_WIFI_IP%%/*}]: " tmp
  WIFI_IP="${tmp:-${DEFAULT_WIFI_IP%%/*}}/24"
  read -r -p "Plage DHCP (début) [${DEFAULT_DHCP_START}]: " tmp
  DHCP_START="${tmp:-$DEFAULT_DHCP_START}"
  read -r -p "Plage DHCP (fin) [${DEFAULT_DHCP_END}]: " tmp
  DHCP_END="${tmp:-$DEFAULT_DHCP_END}"
}

# If already saved config exists in /etc/router.conf we can read it
load_saved_config() {
  if [ -f /etc/router.conf ]; then
    # shellcheck source=/dev/null
    source /etc/router.conf
    return 0
  fi
  return 1
}

save_config() {
  cat > /etc/router.conf <<EOF
ETH_IF="${ETH_IF}"
WIFI_IF="${WIFI_IF}"
SSID="${SSID}"
PSK="${PSK}"
WIFI_IP="${WIFI_IP}"
DHCP_START="${DHCP_START}"
DHCP_END="${DHCP_END}"
EOF
  chmod 600 /etc/router.conf
  log "Configuration sauvegardée dans /etc/router.conf"
}

# --- Création des confs hostapd et dnsmasq ---
create_hostapd_conf() {
  if [ -f "${HOSTAPD_CONF}" ]; then
    cp -v "${HOSTAPD_CONF}" "${HOSTAPD_CONF}.bak.$(date +%s)" || true
    warn "Sauvegarde de l'ancien ${HOSTAPD_CONF}"
  fi

  cat > "${HOSTAPD_CONF}" <<EOF
interface=${WIFI_IF}
driver=nl80211
ssid=${SSID}
hw_mode=g
channel=6
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${PSK}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

  log "Fichier hostapd écrit dans ${HOSTAPD_CONF}"
  # Indiquer à hostapd d'utiliser ce fichier (fichier /etc/default/hostapd)
  if [ -f /etc/default/hostapd ]; then
    if grep -q "^DAEMON_CONF=" /etc/default/hostapd; then
      sudo sed -i "s|^DAEMON_CONF=.*|DAEMON_CONF=\"${HOSTAPD_CONF}\"|" /etc/default/hostapd
    else
      echo "DAEMON_CONF=\"${HOSTAPD_CONF}\"" | sudo tee -a /etc/default/hostapd >/dev/null
    fi
  else
    echo "DAEMON_CONF=\"${HOSTAPD_CONF}\"" | sudo tee /etc/default/hostapd >/dev/null
  fi
}

create_dnsmasq_conf() {
  if [ -f "${DNSMASQ_CONF}" ]; then
    cp -v "${DNSMASQ_CONF}" "${DNSMASQ_CONF}.bak.$(date +%s)" || true
    warn "Sauvegarde de l'ancien ${DNSMASQ_CONF}"
  fi

  cat > "${DNSMASQ_CONF}" <<EOF
interface=${WIFI_IF}
bind-interfaces
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,24h
dhcp-option=3,${WIFI_IP%%/*}
dhcp-option=6,8.8.8.8,8.8.4.4
EOF

  log "Fichier dnsmasq écrit dans ${DNSMASQ_CONF}"
}

# --- Actions start / stop / status ---
do_start() {
  # Vérifications basiques
  if ! ip link show "${ETH_IF}" >/dev/null 2>&1; then
    err "Interface internet ${ETH_IF} introuvable. Vérifie le nom et relance."
    exit 2
  fi
  if ! ip link show "${WIFI_IF}" >/dev/null 2>&1; then
    err "Interface Wi‑Fi ${WIFI_IF} introuvable. Vérifie le nom et relance."
    exit 2
  fi

  log "Assignation IP statique à ${WIFI_IF} (${WIFI_IP})"
  # if IP already exists, ignore
  if ! ip addr show dev "${WIFI_IF}" | grep -q "${WIFI_IP%%/*}"; then
    ip addr add "${WIFI_IP}" dev "${WIFI_IF}" 2>/dev/null || {
      warn "Impossible d'ajouter l'IP (peut-être déjà présente)."
    }
  else
    log "IP déjà présente sur ${WIFI_IF}"
  fi
  ip link set "${WIFI_IF}" up

  # activer forwarding
  log "Activation de l'IP forwarding"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  # créer confs si besoin
  create_hostapd_conf
  create_dnsmasq_conf

  # démarrer hostapd, attendre un peu pour que l'interface AP soit prête
  log "Démarrage de hostapd"
  systemctl unmask hostapd >/dev/null 2>&1 || true
  systemctl enable --now hostapd || {
    warn "Échec du démarrage automatique de hostapd via systemd. Tentative manuelle..."
    hostapd "${HOSTAPD_CONF}" &
    sleep 2
  }

  # attendre que l'interface soit en mode AP
  for i in {1..8}; do
    if iw dev "${WIFI_IF}" info 2>/dev/null | grep -q "type AP"; then
      log "Interface ${WIFI_IF} en mode AP détectée."
      break
    fi
    log "En attente du mode AP sur ${WIFI_IF} (tentative $i/8)…"
    sleep 1
  done

  # démarrer dnsmasq
  log "Démarrage de dnsmasq"
  systemctl enable --now dnsmasq || {
    warn "Échec du démarrage via systemd ; tentative manuelle..."
    dnsmasq --conf-file="${DNSMASQ_CONF}" &
    sleep 1
  }

  # Appliquer règles iptables (sans duplication)
  log "Configuration NAT (iptables)"
  # POSTROUTING MASQUERADE
  if ! iptables_has_rule -t nat -C POSTROUTING -o "${ETH_IF}" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -o "${ETH_IF}" -j MASQUERADE
    log "MASQUERADE ajouté sur ${ETH_IF}"
  else
    log "MASQUERADE déjà présent"
  fi

  # FORWARD rules
  if ! iptables_has_rule -C FORWARD -i "${ETH_IF}" -o "${WIFI_IF}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -i "${ETH_IF}" -o "${WIFI_IF}" -m state --state RELATED,ESTABLISHED -j ACCEPT
  fi
  if ! iptables_has_rule -C FORWARD -i "${WIFI_IF}" -o "${ETH_IF}" -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -i "${WIFI_IF}" -o "${ETH_IF}" -j ACCEPT
  fi

  # Optionnel : changer politique FORWARD sur ACCEPT si c'est DROP (faire attention)
  POLICY_FORWARD="$(iptables -L FORWARD -n | sed -n '1p' | awk '{print $4}')"
  if [ "$POLICY_FORWARD" = "DROP" ]; then
    warn "Politique FORWARD est DROP — définition temporaire à ACCEPT pour permettre le routage."
    iptables -P FORWARD ACCEPT
  fi

  # sauvegarder les règles si possible
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save || warn "Échec de la sauvegarde netfilter-persistent"
  else
    warn "netfilter-persistent non installé : installe iptables-persistent si tu veux sauvegarder les règles."
  fi

  # sauvegarder la config si souhaité
  save_config

  log "Démarrage terminé — le SSID '${SSID}' devrait être visible."
}

do_stop() {
  log "Arrêt du point relais"

  # arrêter hostapd et dnsmasq
  systemctl stop dnsmasq 2>/dev/null || true
  systemctl stop hostapd 2>/dev/null || true

  # Supprimer IP statique sur le Wi-Fi (si présente)
  if ip addr show dev "${WIFI_IF}" | grep -q "${WIFI_IP%%/*}"; then
    ip addr del "${WIFI_IP}" dev "${WIFI_IF}" 2>/dev/null || warn "Impossible de supprimer l'IP (déjà supprimée ?)"
  else
    log "IP ${WIFI_IP%%/*} non présente sur ${WIFI_IF}"
  fi

  # Supprimer les règles iptables (si présentes)
  if iptables_has_rule -t nat -C POSTROUTING -o "${ETH_IF}" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -D POSTROUTING -o "${ETH_IF}" -j MASQUERADE || true
  fi
  if iptables_has_rule -C FORWARD -i "${ETH_IF}" -o "${WIFI_IF}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    iptables -D FORWARD -i "${ETH_IF}" -o "${WIFI_IF}" -m state --state RELATED,ESTABLISHED -j ACCEPT || true
  fi
  if iptables_has_rule -C FORWARD -i "${WIFI_IF}" -o "${ETH_IF}" -j ACCEPT 2>/dev/null; then
    iptables -D FORWARD -i "${WIFI_IF}" -o "${ETH_IF}" -j ACCEPT || true
  fi

  # Optionnel : remettre politique FORWARD sur DROP (si tu veux stricte)
  # iptables -P FORWARD DROP

  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save || true
  fi

  log "Arrêt terminé."
}

do_status() {
  echo "=== Statut rapide ==="
  echo "Interface Internet (ETH_IF): ${ETH_IF}"
  echo "Interface Wi‑Fi (WIFI_IF): ${WIFI_IF}"
  echo
  ip addr show "${WIFI_IF}" | sed -n '1,4p'
  echo
  echo "hostapd status:"
  systemctl status hostapd --no-pager
  echo
  echo "dnsmasq status:"
  systemctl status dnsmasq --no-pager
  echo
  echo "iptables POSTROUTING (nat):"
  iptables -t nat -L POSTROUTING -n -v
  echo
  echo "iptables FORWARD:"
  iptables -L FORWARD -n -v
}

# --- MAIN ---
if [ "$(id -u)" -ne 0 ]; then
  err "Ce script doit être exécuté en root. Fais : sudo $0 <start|stop|status|interactive>"
  exit 1
fi

ACTION="${1:-interactive}"

# Load saved config if present
load_saved_config || true

case "$ACTION" in
  interactive)
    get_interfaces_interactive
    save_config
    log "Configuration enregistrée. Pour démarrer le routeur, lance : sudo $0 start"
    ;;
  start)
    # if variables not set, try load saved config, else prompt
    if [ -z "${ETH_IF:-}" ] || [ -z "${WIFI_IF:-}" ]; then
      warn "Aucune configuration détectée. Passage en mode interactif."
      get_interfaces_interactive
    fi
    do_start
    ;;
  stop)
    if [ -z "${ETH_IF:-}" ] || [ -z "${WIFI_IF:-}" ]; then
      warn "Aucune configuration détectée. Impossible d'arrêter proprement sans infos. Lance 'interactive' d'abord."
      exit 2
    fi
    do_stop
    ;;
  status)
    if [ -z "${ETH_IF:-}" ] || [ -z "${WIFI_IF:-}" ]; then
      warn "Aucune configuration détectée. Lance 'interactive' d'abord."
      exit 2
    fi
    do_status
    ;;
  *)
    err "Usage: $0 {start|stop|status|interactive}"
    exit 1
    ;;
esac
