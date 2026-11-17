pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

KCM.SimpleKCM {
    id: page

    property string cfg_theme: "kde"
    property string cfg_themeDefault: "kde"

    property string cfg_accentColor: ""
    property string cfg_accentColorDefault: ""

    property alias cfg_maxTrackWidth: trackWidthSpin.value
    property int cfg_maxTrackWidthDefault: 160

    property alias cfg_volumeStep: volumeStepSpin.value
    property int cfg_volumeStepDefault: 5

    property alias cfg_showVolumeBadge: showVolumeCheck.checked
    property bool cfg_showVolumeBadgeDefault: true

    property alias cfg_showQuotaBadges: showQuotaCheck.checked
    property bool cfg_showQuotaBadgesDefault: true

    property alias cfg_quotaClaudeEnabled: quotaClaudeCheck.checked
    property bool cfg_quotaClaudeEnabledDefault: true
    property alias cfg_quotaAgyEnabled: quotaAgyCheck.checked
    property bool cfg_quotaAgyEnabledDefault: true
    property alias cfg_quotaCodexEnabled: quotaCodexCheck.checked
    property bool cfg_quotaCodexEnabledDefault: true

    property string cfg_quotaWindowMode: "both"
    property string cfg_quotaWindowModeDefault: "both"

    property alias cfg_herdrEnabled: herdrCheck.checked
    property bool cfg_herdrEnabledDefault: true

    property alias cfg_houraEnabled: houraCheck.checked
    property bool cfg_houraEnabledDefault: true

    property string cfg_weatherMode: "off"
    property string cfg_weatherModeDefault: "off"

    property alias cfg_weatherCity: weatherCityField.text
    property string cfg_weatherCityDefault: ""

    property alias cfg_weatherLatitude: weatherLatField.text
    property string cfg_weatherLatitudeDefault: ""

    property alias cfg_weatherLongitude: weatherLonField.text
    property string cfg_weatherLongitudeDefault: ""

    function syncRadios(): void {
        weatherOffRadio.checked = (page.cfg_weatherMode !== "manual" && page.cfg_weatherMode !== "ip");
        weatherManualRadio.checked = (page.cfg_weatherMode === "manual");
        weatherIpRadio.checked = (page.cfg_weatherMode === "ip");
        gruvboxRadio.checked = (page.cfg_theme === "gruvbox");
        kdeRadio.checked = (page.cfg_theme !== "gruvbox");
        quotaBothRadio.checked = (page.cfg_quotaWindowMode !== "5h" && page.cfg_quotaWindowMode !== "7d");
        quota5hRadio.checked = (page.cfg_quotaWindowMode === "5h");
        quota7dRadio.checked = (page.cfg_quotaWindowMode === "7d");
        if (accentField.text !== page.cfg_accentColor) {
            accentField.text = page.cfg_accentColor;
        }
    }

    onCfg_themeChanged: syncRadios()
    onCfg_quotaWindowModeChanged: syncRadios()
    onCfg_accentColorChanged: syncRadios()
    onCfg_weatherModeChanged: syncRadios()
    Component.onCompleted: syncRadios()

    Kirigami.FormLayout {
        anchors.left: parent.left
        anchors.right: parent.right

        QQC2.RadioButton {
            id: kdeRadio
            Kirigami.FormData.label: i18n("Color theme:")
            text: i18n("System color scheme (KDE)")
            onToggled: {
                if (checked) {
                    page.cfg_theme = "kde";
                }
            }
        }

        QQC2.RadioButton {
            id: gruvboxRadio
            text: "Gruvbox Dark"
            onToggled: {
                if (checked) {
                    page.cfg_theme = "gruvbox";
                }
            }
        }

        RowLayout {
            Kirigami.FormData.label: i18n("Custom accent color:")
            spacing: 8

            QQC2.TextField {
                id: accentField
                placeholderText: i18n("#rrggbb (empty = theme accent)")
                Layout.preferredWidth: 200
                onTextEdited: {
                    const trimmed = text.trim();
                    if (trimmed === "" || /^#[0-9a-fA-F]{6}$/.test(trimmed)) {
                        page.cfg_accentColor = trimmed;
                    }
                }
            }

            Rectangle {
                Layout.preferredWidth: 22
                Layout.preferredHeight: 22
                radius: 5
                color: /^#[0-9a-fA-F]{6}$/.test(page.cfg_accentColor) ? page.cfg_accentColor : Kirigami.Theme.highlightColor
                border.width: 1
                border.color: Kirigami.Theme.disabledTextColor
            }

            QQC2.Button {
                text: i18n("Reset")
                enabled: page.cfg_accentColor !== ""
                onClicked: {
                    page.cfg_accentColor = "";
                }
            }
        }

        Item {
            Kirigami.FormData.isSection: true
        }

        QQC2.SpinBox {
            id: trackWidthSpin
            Kirigami.FormData.label: i18n("Max. track title width (px):")
            from: 80
            to: 360
            stepSize: 10
        }

        QQC2.SpinBox {
            id: volumeStepSpin
            Kirigami.FormData.label: i18n("Wheel volume step (%):")
            from: 1
            to: 20
            stepSize: 1
        }

        QQC2.CheckBox {
            id: showVolumeCheck
            Kirigami.FormData.label: i18n("Panel badges:")
            text: i18n("Show volume percentage badge")
        }

        QQC2.CheckBox {
            id: showQuotaCheck
            text: i18n("Show quota rings")
        }

        QQC2.CheckBox {
            id: quotaClaudeCheck
            Kirigami.FormData.label: i18n("Quota providers:")
            text: "Claude"
        }

        QQC2.CheckBox {
            id: quotaAgyCheck
            text: "Antigravity (AGY)"
        }

        QQC2.CheckBox {
            id: quotaCodexCheck
            text: "ChatGPT / Codex"
        }

        QQC2.Label {
            text: i18n("A provider without credentials is hidden even when enabled.")
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            opacity: 0.7
        }

        Item {
            Kirigami.FormData.isSection: true
        }

        QQC2.RadioButton {
            id: quotaBothRadio
            Kirigami.FormData.label: i18n("Idle quota badge:")
            text: i18n("Hourly and weekly together (5h·7d)")
            enabled: showQuotaCheck.checked
            onToggled: {
                if (checked) {
                    page.cfg_quotaWindowMode = "both";
                }
            }
        }

        QQC2.RadioButton {
            id: quota5hRadio
            text: i18n("Hourly window only (5h)")
            enabled: showQuotaCheck.checked
            onToggled: {
                if (checked) {
                    page.cfg_quotaWindowMode = "5h";
                }
            }
        }

        QQC2.RadioButton {
            id: quota7dRadio
            text: i18n("Weekly window only (7d)")
            enabled: showQuotaCheck.checked
            onToggled: {
                if (checked) {
                    page.cfg_quotaWindowMode = "7d";
                }
            }
        }

        Item {
            Kirigami.FormData.isSection: true
        }

        QQC2.CheckBox {
            id: herdrCheck
            Kirigami.FormData.label: i18n("Optional integrations:")
            text: i18n("Herdr agents (if hc is installed)")
        }

        QQC2.CheckBox {
            id: houraCheck
            text: i18n("Houra focus summary (if the database exists)")
        }

        Item {
            Kirigami.FormData.isSection: true
        }

        QQC2.RadioButton {
            id: weatherOffRadio
            Kirigami.FormData.label: i18n("Weather:")
            text: i18n("Off (no network requests)")
            onToggled: {
                if (checked) {
                    page.cfg_weatherMode = "off";
                }
            }
        }

        QQC2.RadioButton {
            id: weatherManualRadio
            text: i18n("Manual location (Open-Meteo)")
            onToggled: {
                if (checked) {
                    page.cfg_weatherMode = "manual";
                }
            }
        }

        QQC2.RadioButton {
            id: weatherIpRadio
            text: i18n("Locate me by IP address (your IP is sent to ipwho.is)")
            onToggled: {
                if (checked) {
                    page.cfg_weatherMode = "ip";
                }
            }
        }

        QQC2.TextField {
            id: weatherCityField
            Kirigami.FormData.label: i18n("City:")
            enabled: weatherManualRadio.checked
            placeholderText: i18n("e.g. Berlin")
            Layout.preferredWidth: 200
        }

        RowLayout {
            Kirigami.FormData.label: i18n("Coordinates (optional):")
            enabled: weatherManualRadio.checked
            spacing: 8

            QQC2.TextField {
                id: weatherLatField
                placeholderText: i18n("latitude")
                Layout.preferredWidth: 96
                validator: DoubleValidator { bottom: -90; top: 90; notation: DoubleValidator.StandardNotation; locale: "C" }
            }

            QQC2.TextField {
                id: weatherLonField
                placeholderText: i18n("longitude")
                Layout.preferredWidth: 96
                validator: DoubleValidator { bottom: -180; top: 180; notation: DoubleValidator.StandardNotation; locale: "C" }
            }
        }

        QQC2.Label {
            Layout.fillWidth: true
            text: i18n("Tip: on the panel capsule, the mouse wheel changes the volume, middle click toggles mute, and left click opens the full Quota Island window.")
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            opacity: 0.75
            font: Kirigami.Theme.smallFont
        }
    }
}
