pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami

// Gruvbox Dark (kdeglobals) ve KDE Sistem Teması renk/stil belirteçleri.
// Not: Qt 6 QQuickItem.palette özelliğini gölgelememek için `look` kullanılır.
Item {
    id: root

    // Görünmez yapılmaz (visible: false olursa Kirigami.Theme renkleri siyaha düşer).
    implicitWidth: 0
    implicitHeight: 0

    // "kde" (varsayılan: kullanıcının sistem renk şeması) | "gruvbox"
    property string name: "kde"
    property string accentOverride: ""

    readonly property bool isGruvbox: name === "gruvbox"
    readonly property bool isKde: !isGruvbox

    Kirigami.Theme.colorSet: Kirigami.Theme.Window
    Kirigami.Theme.inherit: false

    function _validHex(value: string): bool {
        return /^#[0-9a-fA-F]{6}$/.test(value);
    }

    function _blend(fg: color, bg: color, ratio: real): color {
        return Qt.rgba(
            bg.r + (fg.r - bg.r) * ratio,
            bg.g + (fg.g - bg.g) * ratio,
            bg.b + (fg.b - bg.b) * ratio,
            1.0
        );
    }

    readonly property var look: {
        if (root.isKde) {
            // Kullanıcının etkin KDE renk şemasından tüm tokenlar türetilir (koyu ve açık şemalar).
            const bg = Kirigami.Theme.backgroundColor;
            const fg = Kirigami.Theme.textColor;
            const hi = Kirigami.Theme.highlightColor;
            const dark = (0.2126 * bg.r + 0.7152 * bg.g + 0.0722 * bg.b) < 0.5;
            const deep = dark ? Qt.rgba(0, 0, 0, 1) : Qt.rgba(1, 1, 1, 1);
            return {
                background: bg,
                surface: root._blend(fg, bg, 0.07),
                surfaceAlt: root._blend(fg, bg, 0.15),
                pillBg: bg,
                border: root._blend(fg, bg, 0.22),
                text: fg,
                subtext: root._blend(fg, bg, 0.68),
                mutedText: root._blend(fg, bg, 0.46),
                accent: hi,
                accentBright: dark ? root._blend(fg, hi, 0.45) : hi,
                amber: dark ? root._blend(fg, hi, 0.45) : hi,
                amberDim: root._blend(hi, bg, 0.78),
                positive: root._blend(fg, root._blend(hi, Kirigami.Theme.positiveTextColor, 0.35), 0.22),
                neutral: root._blend(fg, root._blend(hi, Kirigami.Theme.neutralTextColor, 0.40), 0.20),
                negative: root._blend(fg, Kirigami.Theme.negativeTextColor, 0.18),
                obsidian: root._blend(deep, bg, dark ? 0.40 : 0.55),
                aqua: root._blend(fg, Kirigami.Theme.linkColor, 0.18),
                orange: root._blend(fg, Kirigami.Theme.neutralTextColor, 0.18),
                purple: root._blend(fg, Kirigami.Theme.visitedLinkColor, 0.25),
                blue: root._blend(fg, Kirigami.Theme.activeTextColor, 0.22)
            };
        }
        // Sıcak Gruvbox Dark paleti.
        return {
            background: "#1d2021",
            surface: "#282828",
            surfaceAlt: "#3c3836",
            pillBg: "#1d2021",
            border: "#504945",
            text: "#ebdbb2",
            subtext: "#a89984",
            mutedText: "#7c6f64",
            accent: "#d79921",
            accentBright: "#fabd2f",
            positive: "#b8bb26",
            amber: "#fabd2f",
            neutral: "#fabd2f",
            negative: "#fb4934",
            obsidian: "#141617",
            amberDim: "#d79921",
            aqua: "#8ec07c",
            orange: "#fe8019",
            purple: "#d3869b",
            blue: "#83a598"
        };
    }

    readonly property color background: look.background
    readonly property color surface: look.surface
    readonly property color surfaceAlt: look.surfaceAlt
    readonly property color pillBg: look.pillBg
    readonly property color border: look.border
    readonly property color text: look.text
    readonly property color onSurface: look.text
    readonly property color subtext: look.subtext
    readonly property color mutedText: look.mutedText
    readonly property color accent: _validHex(accentOverride) ? accentOverride : look.accent
    readonly property color accentBright: _validHex(accentOverride) ? Qt.lighter(accent, 1.35) : look.accentBright
    readonly property color positive: look.positive
    readonly property color neutral: look.neutral
    readonly property color warning: look.neutral
    readonly property color negative: look.negative
    readonly property color danger: look.negative
    readonly property color divider: Qt.rgba(text.r, text.g, text.b, 0.10)

    // Tasarım belirteçleri
    readonly property color obsidian: look.obsidian
    // Çerçevesiz tonal kart yüzeyleri
    // v3.1 cam: Plasma'nın bulanık popup zemini üstünde metin renginden türeyen yarı saydam katmanlar
    // (her renk şemasında, koyu ve açık, kendiliğinden doğru tonu verir).
    readonly property color card: Qt.rgba(text.r, text.g, text.b, 0.06)
    readonly property color cardAlt: Qt.rgba(text.r, text.g, text.b, 0.11)
    readonly property color glassBorder: Qt.rgba(text.r, text.g, text.b, 0.08)
    readonly property color glassPill: Qt.rgba(obsidian.r, obsidian.g, obsidian.b, 0.58)
    readonly property color amber: _validHex(accentOverride) ? accentBright : look.amber
    readonly property color amberDim: look.amberDim
    readonly property color olive: look.positive
    readonly property color aqua: look.aqua
    readonly property color orange: look.orange
    readonly property color coral: look.negative
    readonly property color purple: look.purple
    readonly property color blue: look.blue
    // 1px sıcak krem iç rim (ışık kırılması) ve üst parlama
    readonly property color rim: Qt.rgba(text.r, text.g, text.b, 0.14)
    readonly property color rimStrong: Qt.rgba(accentBright.r, accentBright.g, accentBright.b, 0.55)
    readonly property color sheen: Qt.rgba(text.r, text.g, text.b, 0.055)
    readonly property color track: Qt.rgba(text.r, text.g, text.b, 0.09)

    function tint(c: color, alpha: real): color {
        return Qt.rgba(c.r, c.g, c.b, alpha);
    }

    // Tipografi ve boyut belirteçleri
    readonly property string fontFamily: Kirigami.Theme.defaultFont.family
    readonly property string monoFamily: "MesloLGS Nerd Font Mono"
    readonly property int fontMicro: 9
    readonly property int fontSmall: 10
    readonly property int fontBody: 12
    readonly property int fontTitle: 14
    readonly property int fontDisplay: 22
    readonly property int radiusSmall: 8
    readonly property int radiusMedium: 12
    readonly property int radiusLarge: 18
    readonly property int radiusCard: 20
    readonly property int radiusPill: 999
    readonly property int gap: 8
    readonly property int pad: 12
    readonly property int animFast: 140
    readonly property int animNormal: 240
    readonly property int animMorph: 380
    // Sabit popup ölçüsü: kontrol merkezi + medya + hava durumu için 560x476
    readonly property int popupWidth: 560
    readonly property int popupHeight: 476

    function quotaColor(usedPct: real): color {
        if (usedPct < 0) {
            return root.subtext;
        }
        if (usedPct >= 85) {
            return root.negative;
        }
        if (usedPct >= 60) {
            return root.warning;
        }
        return root.positive;
    }
}
