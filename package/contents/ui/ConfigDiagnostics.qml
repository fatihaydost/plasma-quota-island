pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

// Teşhis sayfası: isteğe bağlı araçların ve sağlayıcı kimliklerinin yalnız var/yok durumu.
KCM.SimpleKCM {
    id: page

    property var diag: ({})
    property bool loading: false

    readonly property string _scriptPath: {
        const resolved = Qt.resolvedUrl("../scripts/live_ctl.py").toString();
        return resolved.startsWith("file://") ? decodeURIComponent(resolved.slice(7)) : resolved;
    }

    function refresh(): void {
        page.loading = true;
        const quoted = "'" + page._scriptPath.replace(/'/g, "'\\''") + "'";
        runner.run("/usr/bin/python3 " + quoted + " diagnostics", function(stdout, _stderr, exitCode) {
            page.loading = false;
            try {
                page.diag = exitCode === 0 ? JSON.parse(String(stdout || "{}")) : {};
            } catch (e) {
                page.diag = {};
            }
        });
    }

    function found(group: string, key: string): bool {
        return Boolean(page.diag && page.diag[group] && page.diag[group][key]);
    }

    Component.onCompleted: refresh()

    Exec {
        id: runner
    }

    component StatusRow: RowLayout {
        id: row

        property string label: ""
        property bool ok: false

        Kirigami.FormData.label: row.label
        spacing: Kirigami.Units.smallSpacing
        Accessible.role: Accessible.StaticText
        Accessible.name: row.ok ? i18n("%1: found", row.label) : i18n("%1: not found", row.label)

        Kirigami.Icon {
            source: row.ok ? "emblem-ok-symbolic" : "emblem-unavailable-symbolic"
            color: row.ok ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
        }

        QQC2.Label {
            text: page.loading ? i18n("Checking…") : (row.ok ? i18n("Found") : i18n("Not found"))
            textFormat: Text.PlainText
        }
    }

    Kirigami.FormLayout {
        anchors.left: parent.left
        anchors.right: parent.right

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Audio")
        }
        StatusRow { label: "wpctl (PipeWire)"; ok: page.found("tools", "wpctl") }
        StatusRow { label: "pactl (PulseAudio)"; ok: page.found("tools", "pactl") }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("System")
        }
        StatusRow { label: "powerprofilesctl"; ok: page.found("tools", "powerprofilesctl") }
        StatusRow { label: "upower"; ok: page.found("tools", "upower") }
        StatusRow { label: "bluetoothctl"; ok: page.found("tools", "bluetoothctl") }
        StatusRow { label: "nmcli"; ok: page.found("tools", "nmcli") }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Optional integrations")
        }
        StatusRow { label: "hc (Herdr)"; ok: page.found("tools", "hc") }
        StatusRow { label: "herdr-app"; ok: page.found("tools", "herdr-app") }
        StatusRow { label: i18n("Houra database"); ok: page.found("files", "houraDb") }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Quota credentials")
        }
        StatusRow { label: "Claude"; ok: page.found("credentials", "claude") }
        StatusRow { label: "Antigravity (AGY)"; ok: page.found("credentials", "agy") }
        StatusRow { label: "ChatGPT / Codex"; ok: page.found("credentials", "codex") }

        QQC2.Button {
            Kirigami.FormData.label: ""
            text: i18n("Check again")
            icon.name: "view-refresh-symbolic"
            enabled: !page.loading
            onClicked: page.refresh()
        }

        QQC2.Label {
            Layout.fillWidth: true
            text: i18n("Only presence is checked. No paths, tokens or credential contents are read into this page.")
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            opacity: 0.75
            font: Kirigami.Theme.smallFont
        }
    }
}
