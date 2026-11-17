#!/usr/bin/env bash
# Quota Island (io.github.fatihaydost.island) kurulum ve güncelleme betiği.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID="io.github.fatihaydost.island"
RELOAD=0
REMOVE=0

usage() {
    cat <<EOF
Kullanım: ./install.sh [--reload] [--remove]

Seçenekler:
  --reload             Kurulum veya güncelleme sonrasında plasmashell'i yeniden başlatır.
  --remove, --uninstall Kurulu widget paketini sistemden kaldırır.
  -h, --help           Bu yardım metnini gösterir.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --reload)
            RELOAD=1
            ;;
        --remove|--uninstall)
            REMOVE=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Bilinmeyen seçenek: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if ! command -v kpackagetool6 >/dev/null 2>&1; then
    echo "Hata: kpackagetool6 bulunamadı. Bu widget KDE Plasma 6 gerektirir." >&2
    exit 1
fi

if (( REMOVE )); then
    if kpackagetool6 --type Plasma/Applet --show "$ID" >/dev/null 2>&1; then
        echo "$ID kaldırılıyor..."
        kpackagetool6 --type Plasma/Applet --remove "$ID"
        echo "Kaldırıldı."
        echo "Önbellek ve raf verisi silinmedi: ${XDG_CACHE_HOME:-$HOME/.cache}/plasma-quota-island"
    else
        echo "$ID zaten kurulu değil."
    fi
    exit 0
fi

# Widget betikleri sabit /usr/bin/python3 ile çağırır (plasmashell PATH'ine güvenilmez).
if [[ ! -x /usr/bin/python3 ]]; then
    echo "Hata: /usr/bin/python3 bulunamadı; widget arka ucu Python 3 gerektirir." >&2
    exit 1
fi

# İsteğe bağlı araçlar: yoksa ilgili bölüm sessizce gizlenir, kurulum sürer.
missing=()
for tool in wpctl pactl powerprofilesctl upower bluetoothctl nmcli wl-copy xclip; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
/usr/bin/python3 -c "import gi" >/dev/null 2>&1 || missing+=("python-gobject (medya)")
if (( ${#missing[@]} )); then
    echo "Bilgi: bulunamayan isteğe bağlı araçlar (ilgili bölümler gizlenir): ${missing[*]}"
fi

if [[ ! -d "$ROOT/package" ]]; then
    echo "Hata: Paket dizini bulunamadı: $ROOT/package" >&2
    exit 1
fi

for script_name in island_ctl.py live_ctl.py; do
    if [[ -f "$ROOT/package/contents/scripts/$script_name" ]]; then
        chmod +x "$ROOT/package/contents/scripts/$script_name"
    fi
done

upgraded=0
if kpackagetool6 --type Plasma/Applet --show "$ID" >/dev/null 2>&1; then
    echo "$ID güncelleniyor..."
    kpackagetool6 --type Plasma/Applet --upgrade "$ROOT/package"
    upgraded=1
else
    echo "$ID kuruluyor..."
    kpackagetool6 --type Plasma/Applet --install "$ROOT/package"
fi

INSTALLED_SCRIPTS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids/$ID/contents/scripts"
for script_name in island_ctl.py live_ctl.py; do
    if [[ -f "$INSTALLED_SCRIPTS_DIR/$script_name" ]]; then
        chmod +x "$INSTALLED_SCRIPTS_DIR/$script_name"
    fi
done

echo
echo "Tamamlandı. Üst panele sağ tıklayın -> Araç Takımları Ekle... -> Quota Island"
echo

if (( RELOAD )); then
    echo "Yeni QML kodunun yüklenmesi için plasmashell yeniden başlatılıyor..."
    if systemctl --user is-active --quiet plasma-plasmashell.service; then
        systemctl --user restart plasma-plasmashell.service
    else
        kquitapp6 plasmashell 2>/dev/null || pkill -x plasmashell || true
        sleep 1
        setsid plasmashell >/dev/null 2>&1 < /dev/null &
    fi
    echo "plasmashell yeniden başlatıldı."
elif (( upgraded )); then
    echo "Panelde açık bir kopya varsa yeni kodu alması için kabuğu yenileyin:"
    echo "  ./install.sh --reload"
    echo "  veya: systemctl --user restart plasma-plasmashell.service"
fi
