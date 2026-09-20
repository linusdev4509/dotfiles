#!/usr/bin/env bash
# reinstall-debian-neo-v3.sh
# Reconstrucción basada en .bash_history, .zsh_history y .zshrc revisados.
# Debian Forky/Testing / MacBook Pro 2012
# Esquema de reinstalación:
#   /            -> SE REINSTALA / FORMATEA
#   /home        -> PARTICIÓN SEPARADA, SE CONSERVA Y NO SE RESTAURA
#   /home/neo    -> configuración/datos existentes; NO se sobrescriben masivamente
#   /media/DATOS -> PARTICIÓN SEPARADA, SE CONSERVA; sólo se reconstruye su montaje
#
# IMPORTANTE:
# - Ejecutar como usuario normal con sudo, NO como root.
# - Este script NO sobrescribe automáticamente /etc/fstab, Xorg, keyd o LightDM.
#   Los restaura desde un backup explícito y conserva copia del estado nuevo.
# - El historial muestra pruebas/instalaciones posteriormente eliminadas; se excluyen
#   por defecto de la instalación principal.
# - Este script asume que el instalador de Debian YA terminó y que /home fue montado
#   sin formatearlo. El script NO particiona, NO formatea y NO ejecuta mkfs.
# - DATOS tampoco se formatea ni se modifica; sólo se ayuda a recuperar su entrada
#   de montaje a /media/DATOS.
# - Broadcom BCM4331 [14e4:4331]: ya verificado en esta MacBook.
#   Se usa broadcom-sta-dkms (driver wl); NO se instala b43 en paralelo.
# - Repositorios: la instalación actual ya usa DEB822 generado por Debian
#   (/etc/apt/sources.list.d/debian.sources y debian-backports.sources).
#   Este script NO los reemplaza ni los reescribe.
# - GPU: el historial no identifica inequívocamente el modelo ni un driver propietario.
#   Se instalan herramientas/stack gráfico genérico; luego se muestra lspci para decidir.

set -Eeuo pipefail

USER_NAME="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
if [[ -n "${BACKUP_ROOT:-}" ]]; then
  BACKUP_ROOT="$BACKUP_ROOT"
elif [[ -d "$HOME_DIR/debian-reinstall-backup" ]]; then
  BACKUP_ROOT="$HOME_DIR/debian-reinstall-backup"
elif [[ -d "$HOME_DIR/Downloads/debian-root-backup" ]]; then
  BACKUP_ROOT="$HOME_DIR/Downloads/debian-root-backup"
else
  BACKUP_ROOT="$HOME_DIR/debian-reinstall-backup"
fi
DEBIAN_COMPONENTS="main contrib non-free non-free-firmware"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33mAVISO: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Ejecuta este script como usuario normal; usará sudo cuando corresponda."
command -v sudo >/dev/null || die "sudo no está instalado/configurado."

apt_install() {
  sudo apt-get install -y --no-install-recommends "$@"
}

backup_etc_file() {
  local f="$1"
  if sudo test -e "$f"; then
    sudo cp -a "$f" "${f}.before-neo-reinstall.$(date +%Y%m%d-%H%M%S)"
  fi
}

restore_root_file() {
  # Uso: restore_root_file "etc/keyd/default.conf" "/etc/keyd/default.conf"
  local rel="$1" dst="$2" src="$BACKUP_ROOT/root/$rel"
  if [[ -e "$src" ]]; then
    log "Restaurando $dst desde $src"
    backup_etc_file "$dst"
    sudo install -d -m 0755 "$(dirname "$dst")"
    sudo cp -a "$src" "$dst"
  else
    warn "No existe $src; NO se modifica $dst."
  fi
}

phase_repos() {
  log "1/10 — Debian Forky/Testing: verificar DEB822 y actualizar"

  local main_sources="/etc/apt/sources.list.d/debian.sources"
  local backports_sources="/etc/apt/sources.list.d/debian-backports.sources"

  [[ -f "$main_sources" ]] || die \
    "No existe $main_sources. No crearé repositorios a ciegas: revisa primero la configuración APT."

  log "Repositorios DEB822 instalados por Debian (se conservan sin modificar)"
  sudo cat "$main_sources"
  if [[ -f "$backports_sources" ]]; then
    echo
    sudo cat "$backports_sources"
  fi

  if ! grep -Eq '^Suites: .*(forky|testing)' "$main_sources"; then
    warn "No veo 'forky' o 'testing' en Suites:. Revisa el archivo antes de continuar."
    read -r -p "¿Continuar usando los repositorios actuales sin modificarlos? [y/N] " repo_ok
    [[ "$repo_ok" =~ ^[Yy]$ ]] || exit 1
  fi

  for component in main contrib non-free non-free-firmware; do
    if ! grep -Eq "^Components:.*(^|[[:space:]])${component}([[:space:]]|$)" "$main_sources"; then
      warn "El componente APT '$component' no aparece claramente en $main_sources."
    fi
  done

  # NO ejecutar apt modernize-sources ni generar sources.list:
  # esta instalación ya está correctamente en formato DEB822.
  sudo apt-get update
  sudo apt-get full-upgrade -y
}
phase_base() {
  log "2/10 — Base del sistema, compilación y utilidades"

  apt_install \
    ca-certificates curl wget git openssh-client rsync jq \
    build-essential pkg-config cmake make gcc g++ \
    dkms linux-headers-amd64 \
    zsh fontconfig desktop-file-utils dbus-x11 \
    python3 python3-venv python3-pip pipx \
    zip unzip bzip2 xz-utils p7zip-full unrar \
    tree ripgrep bat \
    acpi brightnessctl rfkill \
    udisks2 exfatprogs dosfstools ntfs-3g \
    libnotify-bin \
    intel-microcode \
    zram-tools

  # Stack gráfico genérico y herramientas de diagnóstico.
  # No instala un driver NVIDIA/AMD propietario porque el historial no demuestra cuál.
  apt_install \
    pciutils mesa-utils \
    xserver-xorg xserver-xorg-input-libinput \
    libinput-tools xinput x11-xserver-utils x11-apps xdotool

  log "Hardware PCI detectado (guardar esta salida antes de decidir driver GPU)"
  lspci -nnk | grep -EA4 'VGA|3D|Display|Network' || true
}

phase_macbook_wifi() {
  log "3/10 — Wi-Fi Broadcom BCM4331 de la MacBook"

  local wifi_info
  wifi_info="$(lspci -nn 2>/dev/null | grep -iE 'Network.*Broadcom|Broadcom.*Network' || true)"
  printf '%s\n' "$wifi_info"

  if grep -qi '14e4:4331' <<<"$wifi_info"; then
    log "Detectado BCM4331 [14e4:4331]: instalando broadcom-sta-dkms (wl)"
    # Evitar mezclar las dos estrategias que aparecieron en el historial.
    sudo apt-get purge -y firmware-b43-installer 2>/dev/null || true
    apt_install dkms linux-headers-amd64 broadcom-sta-dkms rfkill

    echo
    echo "Estado del adaptador después de instalar STA:"
    lspci -nnk | grep -EA4 -i 'network|broadcom' || true
    rfkill list 2>/dev/null || true

    if lsmod | grep -q '^wl '; then
      echo "[OK] módulo wl cargado."
    else
      warn "wl todavía no aparece cargado. Es normal si el módulo anterior sigue activo; reinicia al terminar."
    fi
  else
    warn "No detecté el BCM4331 [14e4:4331]. No instalaré otro driver Broadcom a ciegas."
  fi
}
phase_desktop() {
  log "4/10 — i3/X11, sesión, audio, Bluetooth y utilidades de escritorio"

  apt_install \
    i3 polybar picom rofi nitrogen dunst lxappearance \
    lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings \
    xss-lock xsecurelock \
    blueman bluez pipewire pipewire-pulse wireplumber \
    libspa-0.2-bluetooth pavucontrol alsa-utils \
    flameshot copyq copyq-plugins \
    mousepad thunar thunar-archive-plugin xarchiver file-roller \
    ristretto viewnior galculator \
    papirus-icon-theme breeze-cursor-theme dmz-cursor-theme

  sudo systemctl enable bluetooth.service
  sudo systemctl enable lightdm.service

  # Ajuste observado en el historial; sólo se ejecuta si wpctl está disponible.
  if command -v wpctl >/dev/null; then
    wpctl settings --save bluetooth.autoswitch-to-headset-profile false || true
  fi
}

phase_apps() {
  log "5/10 — Aplicaciones secundarias confirmadas por historial/configuración"

  apt_install \
    chromium \
    zathura libreoffice libreoffice-l10n-es \
    gimp inkscape okular \
    vlc mpv yt-dlp \
    obs-studio \
    calibre foliate \
    keepassxc \
    syncthing borgbackup \
    qpdf poppler-utils img2pdf python3-pil \
    tesseract-ocr tesseract-ocr-spa tesseract-ocr-eng \
    btop htop \
    kitty \
    helix \
    cmus mutt links2 \
    cheese v4l-utils guvcview

  # Paquetes observados pero NO instalados aquí:
  # OnlyOffice, Obsidian, Handy, Zed, Brave, ChatGPT .deb:
  # fueron instalados mediante .deb o instaladores externos y deben tratarse aparte.
}

phase_rust() {
  log "6/10 — Rust/Cargo"

  if [[ ! -x "$HOME_DIR/.cargo/bin/rustup" ]]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  fi

  # shellcheck disable=SC1090
  source "$HOME_DIR/.cargo/env"

  rustup update stable

  # Confirmados en el historial. wlctl fue posteriormente desinstalado, por eso se omite.
  cargo install xcp
  cargo install fcp
  cargo install typst

  # zellij y bat aparecen tanto por APT como Cargo. Preferimos APT si existe en Testing;
  # Cargo sólo actúa como fallback para evitar duplicados.
  command -v zellij >/dev/null || cargo install zellij
  command -v bat >/dev/null || cargo install bat
}

phase_shell() {
  log "7/10 — Zsh, Oh My Zsh, Powerlevel10k y plugins"

  # Oh My Zsh: instalación no interactiva.
  if [[ ! -d "$HOME_DIR/.oh-my-zsh" ]]; then
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  fi

  ZSH_CUSTOM_DIR="${ZSH_CUSTOM:-$HOME_DIR/.oh-my-zsh/custom}"

  [[ -d "$ZSH_CUSTOM_DIR/themes/powerlevel10k/.git" ]] || \
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
      "$ZSH_CUSTOM_DIR/themes/powerlevel10k"

  [[ -d "$ZSH_CUSTOM_DIR/plugins/fast-syntax-highlighting/.git" ]] || \
    git clone --depth=1 https://github.com/zdharma-continuum/fast-syntax-highlighting.git \
      "$ZSH_CUSTOM_DIR/plugins/fast-syntax-highlighting"

  [[ -d "$ZSH_CUSTOM_DIR/plugins/zsh-autosuggestions/.git" ]] || \
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
      "$ZSH_CUSTOM_DIR/plugins/zsh-autosuggestions"

  [[ -d "$ZSH_CUSTOM_DIR/plugins/zsh-completions/.git" ]] || \
    git clone --depth=1 https://github.com/zsh-users/zsh-completions.git \
      "$ZSH_CUSTOM_DIR/plugins/zsh-completions"

  # zoxide/yazi/lsd aparecen activos en el .zshrc.
  apt_install zoxide yazi lsd

  if [[ "$(getent passwd "$USER_NAME" | cut -d: -f7)" != "$(command -v zsh)" ]]; then
    chsh -s "$(command -v zsh)" "$USER_NAME"
  fi
}

phase_external() {
  log "8/10 — Programas externos: preparación, no instalación ciega"

  cat <<'EOF'

El historial demuestra instalaciones externas de:
  - OnlyOffice Desktop Editors (.deb)
  - Obsidian (.deb)
  - Zed (instalador oficial)
  - Brave / Brave Nightly (instalador/repositorio externo)
  - Ollama (instalador externo; después hubo disable/remove parcial)
  - MiMo CLI
  - Qwen Code
  - Google Antigravity CLI
  - OpenAI Codex vía npm
  - Handy (.deb; posteriormente fue eliminado)
  - ChatGPT .deb

No se ejecutan automáticamente porque:
  * varios fueron pruebas o luego eliminados;
  * los .deb concretos deben venir de tu backup/descarga actual;
  * conviene revisar URLs/versiones antes de reinstalar.

EOF

  # npm local observado en .zshrc
  apt_install npm
  mkdir -p "$HOME_DIR/.local/npm"
  npm config set prefix "$HOME_DIR/.local/npm"

  cat <<EOF
Para restaurar Codex, si lo quieres:
  npm install -g @openai/codex

PATH esperado por tu .zshrc:
  $HOME_DIR/.local/bin
  $HOME_DIR/.local/npm/bin
  $HOME_DIR/.mimocode/bin
EOF
}

phase_validate_preserved_partitions() {
  log "9/10 — Verificación de /home preservado y partición DATOS"

  # /home debe existir y contener el perfil antiguo.
  [[ -d "$HOME_DIR" ]] || die "No existe $HOME_DIR. Detengo el proceso para no crear/restaurar HOME por error."

  echo "Usuario actual:"
  id "$USER_NAME"
  echo
  echo "Propietario de HOME:"
  stat -c '  %U:%G  uid=%u gid=%g  %n' "$HOME_DIR"

  cat <<EOF

Este script NO hace rsync sobre $HOME_DIR y NO restaura HOME.
Se espera que la partición /home haya sido conservada durante la reinstalación.

Configuraciones que deberían seguir allí:
  $HOME_DIR/.zshrc
  $HOME_DIR/.p10k.zsh
  $HOME_DIR/.profile
  $HOME_DIR/.config/
  $HOME_DIR/.local/
  $HOME_DIR/.local/bin/
  $HOME_DIR/.local/opt/
  $HOME_DIR/.local/share/applications/
  $HOME_DIR/.local/share/fonts/

Comprobando archivos principales:
EOF

  for p in \
    "$HOME_DIR/.zshrc" \
    "$HOME_DIR/.p10k.zsh" \
    "$HOME_DIR/.config" \
    "$HOME_DIR/.local"
  do
    if [[ -e "$p" ]]; then
      echo "  [OK] $p"
    else
      warn "No encontrado: $p"
    fi
  done

  echo
  echo "Discos y sistemas de archivos actuales:"
  lsblk -f

  echo
  if mountpoint -q /media/DATOS; then
    echo "[OK] /media/DATOS ya está montado:"
    findmnt /media/DATOS || true
  else
    warn "/media/DATOS no está montado."
    warn "No se modificará ni formateará la partición DATOS."
    warn "Usa el fstab respaldado sólo como referencia y verifica primero el UUID con lsblk -f / blkid."
  fi

  # Refresca recursos que viven en el HOME conservado.
  fc-cache -fv >/dev/null 2>&1 || true
  if [[ -d "$HOME_DIR/.local/share/applications" ]]; then
    update-desktop-database "$HOME_DIR/.local/share/applications" 2>/dev/null || true
  fi
}
phase_restore_root() {
  log "10/10 — Configuración especial bajo /etc y /usr"

  cat <<EOF
Rutas ROOT identificadas en los historiales como importantes:

  /etc/keyd/default.conf
      Remapeo de teclado / atajos especiales.

  /etc/X11/xorg.conf.d/30-touchpad.conf
  /etc/X11/xorg.conf.d/90-macbook-touchpad.conf
      Configuración especial del touchpad de la MacBook.

  /etc/default/zramswap
      Configuración ZRAM.

  /etc/lightdm/lightdm.conf
  /etc/lightdm/lightdm-gtk-greeter.conf
      Login/greeter.

  /usr/share/images/desktop-base/
      El historial muestra un fondo personalizado lightdm_1.*

  /etc/fstab
      El fstab antiguo pertenece al root anterior y NO se restaura completo.
      Sólo debe recuperarse, tras verificar UUID, la entrada necesaria para
      montar la partición conservada DATOS en /media/DATOS.

  /etc/network/interfaces
      En la instalación actual Ethernet enp2s0f0 aparece "sin gestión".
      NO se sobrescribe automáticamente: se deja pendiente para diagnosticar
      NetworkManager/interfaces sin arriesgar la conexión Wi-Fi ya funcional.

  /etc/apt/sources.list.d/debian.sources
  /etc/apt/sources.list.d/debian-backports.sources
      La instalación actual ya los generó en formato DEB822 para Forky.
      NO se restauran ni se sobrescriben; sólo se verifican y se usa apt update.

También se compiló ksuperkey con "sudo make install", por lo que puede haber
archivos bajo /usr/local/bin y/o /usr/local. Si dependes de esa herramienta,
es preferible recompilarla o respaldar /usr/local de forma selectiva.
EOF

  # Archivos que sí podemos restaurar de forma controlada desde el backup.
  restore_root_file "etc/keyd/default.conf" "/etc/keyd/default.conf"
  restore_root_file "etc/X11/xorg.conf.d/30-touchpad.conf" "/etc/X11/xorg.conf.d/30-touchpad.conf"
  restore_root_file "etc/X11/xorg.conf.d/90-macbook-touchpad.conf" "/etc/X11/xorg.conf.d/90-macbook-touchpad.conf"
  restore_root_file "etc/default/zramswap" "/etc/default/zramswap"
  restore_root_file "etc/lightdm/lightdm.conf" "/etc/lightdm/lightdm.conf"
  restore_root_file "etc/lightdm/lightdm-gtk-greeter.conf" "/etc/lightdm/lightdm-gtk-greeter.conf"

  # Fondo de LightDM si fue respaldado.
  if [[ -d "$BACKUP_ROOT/root/usr/share/images/desktop-base" ]]; then
    sudo rsync -a "$BACKUP_ROOT/root/usr/share/images/desktop-base/" \
      /usr/share/images/desktop-base/
  fi

  # keyd: el historial muestra que fue eliminado y posteriormente reinstalado/configurado.
  if [[ -f /etc/keyd/default.conf ]]; then
    apt_install keyd
    sudo systemctl enable --now keyd.service || true
    # Algunas builds observadas exponían keyd.rvaiya.
    if command -v keyd.rvaiya >/dev/null; then
      sudo keyd.rvaiya check /etc/keyd/default.conf || true
    elif command -v keyd >/dev/null; then
      sudo keyd check /etc/keyd/default.conf 2>/dev/null || true
    fi
    sudo systemctl restart keyd.service || true
  fi

  sudo systemctl restart bluetooth.service 2>/dev/null || true

  warn "fstab y network/interfaces quedan para revisión manual."
  printf '\nDiscos/UUID actuales:\n'
  lsblk -f
}

main() {
  cat <<EOF
Reconstrucción Debian Forky/Testing v3 para $USER_NAME ($HOME_DIR)
Backup esperado: $BACKUP_ROOT

Fases:
  DEB822 -> base -> BCM4331/wl -> escritorio -> apps -> Rust -> shell
  -> externos -> verificar HOME/DATOS -> configuración ROOT

PARTICIONES:
  /            : Debian nuevo (única partición que se reinstala/formatea)
  /home        : preservada; este script NO la restaura ni la borra
  /media/DATOS : preservada; este script NO la formatea

CAMBIOS CONFIRMADOS EN ESTA REINSTALACIÓN:
  APT          : DEB822 existente; Forky + security + updates + backports
  Wi-Fi        : Broadcom BCM4331 [14e4:4331] -> broadcom-sta-dkms / wl
  Wi-Fi real   : wlp3s0 ya fue capaz de escanear y conectarse
  Ethernet     : enp2s0f0 sin gestión; NO se modifica todavía
EOF

  read -r -p "¿Continuar? [y/N] " ok
  [[ "$ok" =~ ^[Yy]$ ]] || exit 0

  log "Comprobación previa de particiones preservadas"
  if findmnt -T "$HOME_DIR" >/dev/null 2>&1; then
    echo "HOME:"
    findmnt -T "$HOME_DIR" || true
  else
    die "No puedo verificar el sistema de archivos que contiene $HOME_DIR."
  fi
  echo
  echo "El script NO contiene comandos mkfs/parted y no formatea /home ni DATOS."

  phase_repos
  phase_base
  phase_macbook_wifi
  phase_desktop
  phase_apps
  phase_rust
  phase_shell
  phase_external
  phase_validate_preserved_partitions
  phase_restore_root

  log "Finalizado"
  cat <<'EOF'
Revisión final recomendada:
  1. comprobar con findmnt que /home sigue en su partición conservada
  2. lsblk -f / blkid y recuperar SOLO la entrada de DATOS en /etc/fstab
  3. systemctl status keyd bluetooth lightdm
  4. lspci -nnk | grep -EA4 'VGA|3D|Display|Network'
  5. wpctl status
  6. loginctl session-status
  7. comprobar i3/polybar/picom/rofi
  8. comprobar teclado, brillo, touchpad y Wi-Fi
  9. comprobar /media/DATOS
 10. comprobar ~/.local/bin, ~/.local/share/applications y fuentes
 11. reiniciar para asegurar que broadcom-sta-dkms cargue wl
 12. tras reiniciar: lspci -nnk -s 03:00.0 y nmcli device
 13. Ethernet enp2s0f0 'sin gestión' queda como diagnóstico separado
EOF
}

main "$@"
