pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami
import QtQuick.Layouts
import QtQuick.Controls as QQC2

// Alt kontrol merkezi:
// Üst satır (4 MiniTile): Wi-Fi / Kablolu Ağ · Bluetooth · Uyanık Tut (Coffee Mode) · Rahatsız Etme (DND)
// Alt satır: kota sağlayıcı (Claude/AGY/Codex) + Canlı hızlı rozetleri + Panacea 2 tıklamalı güvenli Güç Menüsü (Uyku, Kilitle, Çıkış, Yeniden Başlat, Kapat)
Item {
    id: root

    property var backend: null
    property Theme theme: null

    signal tabRequested(int index)

    Theme {
        id: fallbackTheme
    }

    readonly property Theme lookTheme: root.theme !== null ? root.theme : fallbackTheme

    // Ağ (Wi-Fi / Kablolu)
    readonly property bool wiredOn: Boolean(root.backend && root.backend.wiredOn)
    readonly property string wiredName: (root.backend && root.backend.wiredName) ? String(root.backend.wiredName) : i18n("Wired")
    readonly property bool wifiOn: Boolean(root.backend && root.backend.wifiOn)
    readonly property string wifiSsid: (root.backend && root.backend.wifiSsid) ? String(root.backend.wifiSsid) : ""
    readonly property int wifiQuality: (root.backend && root.backend.wifiQuality !== undefined) ? Number(root.backend.wifiQuality) : 0
    readonly property bool netActive: root.wiredOn || root.wifiOn

    // Bluetooth
    readonly property bool btConnected: Boolean(
        root.backend && root.backend.bluetoothData && root.backend.bluetoothData.connected
    )
    readonly property string btName: (root.backend && root.backend.bluetoothData && root.backend.bluetoothData.name)
        ? String(root.backend.bluetoothData.name)
        : ""
    readonly property int btBattery: (root.backend && root.backend.bluetoothData && root.backend.bluetoothData.battery !== undefined)
        ? Number(root.backend.bluetoothData.battery)
        : -1

    // Modlar (Coffee Mode & DND)
    readonly property bool coffeeActive: Boolean(root.backend && root.backend.coffeeActive)
    readonly property bool dndActive: Boolean(root.backend && root.backend.dndActive)

    // Kotalar & Canlı Ajan Özeti
    // Kota çipleri: "<ad> 5sa·7g%"; yalnız açık ve kimliği bulunan sağlayıcılar (Backend.*Shown)
    // Çipin değer kısmı (ad ayrı çizilir, hiç kısalmaz): 1-2 sağlayıcıda "5·7%", 3+ sağlayıcıda en yüksek tek değer.
    function quotaChipValue(avail: bool, h5: int, d7: int): string {
        if (!avail || h5 < 0) {
            return "";
        }
        if (root.shownProviderCount >= 3) {
            return String(Math.max(h5, d7)) + "%";
        }
        return String(h5) + "·" + String(Math.max(0, d7)) + "%";
    }

    readonly property bool claudeShown: Boolean(root.backend && root.backend.claudeShown)
    readonly property bool agyShown: Boolean(root.backend && root.backend.agyShown)
    readonly property bool codexShown: Boolean(root.backend && root.backend.codexShown)
    readonly property int shownProviderCount: (root.claudeShown ? 1 : 0) + (root.agyShown ? 1 : 0) + (root.codexShown ? 1 : 0)
    readonly property string claudeChipText: root.quotaChipValue(
        Boolean(root.claudeShown && root.backend.claudeQuota.available),
        root.claudeShown ? Number(root.backend.claude5hUsed) : -1,
        root.claudeShown ? Number(root.backend.claude7dUsed) : -1)
    readonly property string agyChipText: root.quotaChipValue(
        Boolean(root.agyShown && root.backend.agyQuota.available),
        root.agyShown ? Math.max(0, Number(root.backend.agyGemini5hUsed), Number(root.backend.agyClaude5hUsed)) : -1,
        root.agyShown ? Number(root.backend.agy7dUsed) : -1)
    readonly property string codexChipText: root.quotaChipValue(
        Boolean(root.codexShown && root.backend.codexQuota.available),
        root.codexShown ? Number(root.backend.codex5hUsed) : -1,
        root.codexShown ? Number(root.backend.codex7dUsed) : -1)

    readonly property int workingAgents: (root.backend && root.backend.herdrWorkingCount !== undefined)
        ? Math.max(0, Math.round(Number(root.backend.herdrWorkingCount))) : 0
    readonly property int blockedAgents: (root.backend && root.backend.herdrBlockedCount !== undefined)
        ? Math.max(0, Math.round(Number(root.backend.herdrBlockedCount))) : 0

    // Kotalar sekmesine götüren tek sağlayıcı çipi
    component QuotaChip: Rectangle {
        id: chip

        property string name: ""
        property string value: ""
        readonly property string label: chip.value !== "" ? (chip.name + " " + chip.value) : chip.name
        property color dotColor: root.lookTheme.amber

        Layout.preferredHeight: 36
        implicitWidth: chipRow.implicitWidth + 12
        // Dar alanda önce değer kısalır; sağlayıcı adı hiç kısalmaz (en küçük genişlik = nokta + ad).
        Layout.fillWidth: true
        Layout.maximumWidth: implicitWidth
        Layout.minimumWidth: 6 + chipRow.spacing + chipName.implicitWidth + 12
        radius: 11
        color: chipMouse.containsMouse ? root.lookTheme.surfaceAlt : root.lookTheme.card
        border.width: 1
        border.color: root.lookTheme.glassBorder

        RowLayout {
            id: chipRow
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            spacing: 4

            Rectangle {
                Layout.preferredWidth: 6
                Layout.preferredHeight: 6
                radius: 3
                color: chip.dotColor
            }

            Text {
                id: chipName
                Layout.minimumWidth: implicitWidth
                text: chip.name
                textFormat: Text.PlainText
                font.family: root.lookTheme.monoFamily
                font.pixelSize: 10
                font.weight: Font.DemiBold
                color: root.lookTheme.text
            }

            Text {
                visible: chip.value !== ""
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: chip.value
                textFormat: Text.PlainText
                elide: Text.ElideRight
                font.family: root.lookTheme.monoFamily
                font.pixelSize: 10
                font.weight: Font.DemiBold
                color: root.lookTheme.text
            }
        }

        MouseArea {
            id: chipMouse
            Accessible.role: Accessible.Button
            Accessible.name: chip.label
            Accessible.onPressAction: root.tabRequested(2)
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.tabRequested(2)
        }
    }

    // 2 tıklamalı güç onayı durumu (Kilitle anında çalışır, diğerleri 4sn içinde 2. tıklama ister)
    property string armedPowerAction: ""

    Timer {
        id: disarmTimer
        interval: 4000
        repeat: false
        onTriggered: {
            root.armedPowerAction = "";
        }
    }

    function triggerPowerButton(actionKey: string, instant: bool): void {
        if (instant) {
            root.armedPowerAction = "";
            if (root.backend && typeof root.backend.runPowerAction === "function") {
                root.backend.runPowerAction(actionKey);
            }
            return;
        }
        if (root.armedPowerAction === actionKey) {
            root.armedPowerAction = "";
            disarmTimer.stop();
            if (root.backend && typeof root.backend.runPowerAction === "function") {
                root.backend.runPowerAction(actionKey);
            }
        } else {
            root.armedPowerAction = actionKey;
            disarmTimer.restart();
        }
    }

    implicitWidth: 532
    implicitHeight: 92

    // Panacea MiniTile bileşeni (aktifken vurgu dolgulu, pasifken tonal kart)
    component MiniTile: Rectangle {
        id: mTile

        property bool activeState: false
        property color activeFillColor: root.lookTheme.amber
        property string iconName: ""
        property string titleText: ""
        property string subText: ""
        signal clicked()

        Layout.fillWidth: true
        Layout.preferredWidth: 1
        Layout.preferredHeight: 46
        radius: 13
        color: mTile.activeState
            ? (mMouse.containsMouse ? Qt.lighter(mTile.activeFillColor, 1.07) : mTile.activeFillColor)
            : (mMouse.containsMouse ? root.lookTheme.surfaceAlt : root.lookTheme.card)
        border.width: mTile.activeState ? 0 : 1
        border.color: root.lookTheme.glassBorder

        Behavior on color {
            ColorAnimation { duration: Kirigami.Units.shortDuration }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 9
            spacing: 8

            Glyph {
                name: mTile.iconName
                size: 16
                color: mTile.activeState ? root.lookTheme.obsidian : root.lookTheme.text
                Layout.alignment: Qt.AlignVCenter
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 0

                Text {
                    Layout.fillWidth: true
                    text: mTile.titleText
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    font.family: root.lookTheme.fontFamily
                    font.pixelSize: 11
                    font.weight: Font.Bold
                    color: mTile.activeState ? root.lookTheme.obsidian : root.lookTheme.text
                }

                Text {
                    Layout.fillWidth: true
                    text: mTile.subText
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    font.family: root.lookTheme.fontFamily
                    font.pixelSize: 9
                    color: mTile.activeState
                        ? Qt.rgba(root.lookTheme.obsidian.r, root.lookTheme.obsidian.g, root.lookTheme.obsidian.b, 0.76)
                        : root.lookTheme.subtext
                }
            }
        }

        MouseArea {
            id: mMouse
            Accessible.role: Accessible.Button
            Accessible.name: mTile.subText !== "" ? i18n("%1: %2", mTile.titleText, mTile.subText) : mTile.titleText
            Accessible.onPressAction: mTile.clicked()
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: mTile.clicked()
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8

        // 1. ÜST SATIR: 4 MiniTile (Wi-Fi / Kablolu · Bluetooth · Uyanık Tut · Rahatsız Etme)
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 46
            spacing: 8

            // Wi-Fi & Kablolu Ağ (aç/kapa nmcli ister; yoksa gizli)
            MiniTile {
                visible: Boolean(root.backend && root.backend.wifiControlShown)
                activeState: root.netActive
                activeFillColor: root.lookTheme.amber
                iconName: root.wiredOn && !root.wifiOn
                    ? "network-wired-symbolic"
                    : (root.wifiOn ? "network-wireless-connected-100-symbolic" : "network-wireless-disconnected-symbolic")
                titleText: root.wifiOn && root.wifiSsid !== ""
                    ? root.wifiSsid
                    : (root.wiredOn ? i18n("Wired network") : i18n("Wi-Fi"))
                subText: root.wifiOn && root.wifiSsid !== ""
                    ? (root.wiredOn ? i18n("%1% + LAN", root.wifiQuality) : i18n("%1% connected", root.wifiQuality))
                    : (root.wiredOn ? root.wiredName : (root.wifiOn ? i18n("On") : i18n("Off")))
                onClicked: {
                    if (root.backend && typeof root.backend.toggleWifi === "function") {
                        root.backend.toggleWifi();
                    }
                }
            }

            // Bluetooth (bluetoothctl yoksa gizli)
            MiniTile {
                visible: Boolean(root.backend && root.backend.bluetoothShown)
                activeState: root.btConnected
                activeFillColor: root.lookTheme.aqua
                iconName: "preferences-system-bluetooth-symbolic"
                titleText: root.btConnected && root.btName !== "" ? root.btName : i18n("Bluetooth")
                subText: root.btConnected
                    ? (root.btBattery >= 0 ? i18n("%1% battery", root.btBattery) : i18n("Connected"))
                    : i18n("Ready")
                onClicked: {
                    if (root.backend && typeof root.backend.toggleBluetooth === "function") {
                        root.backend.toggleBluetooth();
                    }
                }
            }

            // Uyanık Tut (Coffee Mode)
            MiniTile {
                activeState: root.coffeeActive
                activeFillColor: root.lookTheme.olive
                iconName: "preferences-desktop-screensaver-symbolic"
                titleText: i18n("Keep Awake")
                subText: root.coffeeActive ? i18n("On · Sleep blocked") : i18n("Off")
                onClicked: {
                    if (root.backend && typeof root.backend.toggleCoffee === "function") {
                        root.backend.toggleCoffee();
                    }
                }
            }

            // Rahatsız Etme (DND)
            MiniTile {
                activeState: root.dndActive
                activeFillColor: root.lookTheme.coral
                iconName: root.dndActive ? "notifications-disabled-symbolic" : "preferences-desktop-notification-bell-symbolic"
                titleText: i18n("Do Not Disturb")
                subText: root.dndActive ? i18n("On · Silenced") : i18n("Notifications on")
                onClicked: {
                    if (root.backend && typeof root.backend.toggleDnd === "function") {
                        root.backend.toggleDnd();
                    }
                }
            }
        }

        // 2. ALT SATIR: Sol Hızlı Kota/Ajan Rozetleri · Sağ Panacea 5 Düğmeli Güç Menüsü (2 Tıklamalı Onaylı)
        RowLayout {
            id: bottomRow
            Layout.fillWidth: true
            Layout.preferredHeight: 38
            spacing: 6

            // Sol: kota sağlayıcı çipleri + Canlı hızlı geçiş çipi (kalan alanı alır, gerekirse küçülür)
            RowLayout {
                id: chipGroup
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                clip: true
                spacing: 4

                // Kota çiplerinin tam genişliği; ajan çipi önce daralır (yalnız sayı), sonra kota değerleri kısalır.
                readonly property real quotaNeed: (claudeChip.visible ? claudeChip.implicitWidth + spacing : 0)
                    + (agyChip.visible ? agyChip.implicitWidth + spacing : 0)
                    + (codexChip.visible ? codexChip.implicitWidth + spacing : 0)

                QuotaChip {
                    id: claudeChip
                    visible: root.claudeShown
                    name: "Claude"
                    value: root.claudeChipText
                    dotColor: root.lookTheme.orange
                }

                QuotaChip {
                    id: agyChip
                    visible: root.agyShown
                    name: "AGY"
                    value: root.agyChipText
                    dotColor: root.lookTheme.aqua
                }

                QuotaChip {
                    id: codexChip
                    visible: root.codexShown
                    name: "Codex"
                    value: root.codexChipText
                    dotColor: root.lookTheme.blue
                }

                // Canlı Ajan çipi (Herdr yok/kapalıysa gizli)
                Rectangle {
                    id: liveChip
                    visible: Boolean(root.backend && root.backend.herdrShown)
                    readonly property string fullLabel: root.blockedAgents > 0
                        ? i18np("%1 approval", "%1 approvals", root.blockedAgents)
                        : i18np("%1 agent", "%1 agents", root.workingAgents)
                    readonly property string countLabel: String(root.blockedAgents > 0 ? root.blockedAgents : root.workingAgents)
                    // Genişlikler metin ölçüsünden; gösterilen metin değişince döngü oluşmaz.
                    readonly property real chrome: 6 + 4 + 12
                    readonly property real fullWidth: fullMetrics.advanceWidth + chrome + 1
                    readonly property real compactWidth: countMetrics.advanceWidth + chrome + 1
                    // Kullanılabilir alan çip grubunun kendisinden değil satırdan hesaplanır (bağlama döngüsü olmaz).
                    readonly property bool roomy: bottomRow.width - powerStrip.width - bottomRow.spacing >= chipGroup.quotaNeed + fullWidth
                    Layout.preferredHeight: 36
                    implicitWidth: roomy ? fullWidth : compactWidth
                    Layout.maximumWidth: implicitWidth
                    Layout.minimumWidth: compactWidth

                    TextMetrics {
                        id: fullMetrics
                        text: liveChip.fullLabel
                        font: liveText.font
                    }

                    TextMetrics {
                        id: countMetrics
                        text: liveChip.countLabel
                        font: liveText.font
                    }
                    radius: 11
                    color: liveMouse.containsMouse ? root.lookTheme.surfaceAlt : root.lookTheme.card
                    border.width: 1
                    border.color: root.lookTheme.glassBorder

                    RowLayout {
                        id: liveChipRow
                        anchors.fill: parent
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        spacing: 4

                        Rectangle {
                            Layout.preferredWidth: 6
                            Layout.preferredHeight: 6
                            radius: 3
                            color: root.blockedAgents > 0
                                ? root.lookTheme.coral
                                : (root.workingAgents > 0 ? root.lookTheme.aqua : root.lookTheme.mutedText)
                        }

                        Text {
                            id: liveText
                            text: liveChip.roomy ? liveChip.fullLabel : liveChip.countLabel
                            Layout.fillWidth: true
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            font.family: root.lookTheme.monoFamily
                            font.pixelSize: 10
                            font.weight: Font.DemiBold
                            color: root.blockedAgents > 0 ? root.lookTheme.coral : root.lookTheme.text
                        }
                    }

                    MouseArea {
                        id: liveMouse
                        Accessible.role: Accessible.Button
                        Accessible.name: i18n("%1 · %2", i18n("Open Live tab"), liveChip.fullLabel)
                        Accessible.onPressAction: root.tabRequested(3)
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.tabRequested(3)
                    }

                    QQC2.ToolTip.visible: liveMouse.containsMouse
                    QQC2.ToolTip.text: liveChip.fullLabel
                    QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                }
            }

            // Sağ: 5 Düğmeli Güç Çubuğu (Uyku, Kilitle, Çıkış, Yeniden Başlat, Kapat)
            RowLayout {
                id: powerStrip
                spacing: 3

                readonly property var actionsModel: [
                    { key: "sleep", label: i18nc("@action:button suspend", "Sleep"), icon: "system-suspend-symbolic", danger: false, instant: false, zzz: true },
                    { key: "lock", label: i18nc("@action:button", "Lock"), icon: "system-lock-screen-symbolic", danger: false, instant: true, zzz: false },
                    { key: "logout", label: i18nc("@action:button log out", "Log Out"), icon: "system-log-out-symbolic", danger: false, instant: false, zzz: false },
                    { key: "reboot", label: i18nc("@action:button reboot", "Restart"), icon: "system-reboot-symbolic", danger: false, instant: false, zzz: false },
                    { key: "poweroff", label: i18nc("@action:button power off", "Shut Down"), icon: "system-shutdown-symbolic", danger: true, instant: false, zzz: false }
                ]

                Repeater {
                    model: powerStrip.actionsModel

                    delegate: Rectangle {
                        id: pwrBtn

                        required property var modelData
                        required property int index

                        readonly property string actKey: String(modelData.key)
                        readonly property string actLabel: String(modelData.label)
                        readonly property string actIcon: String(modelData.icon)
                        readonly property bool isDanger: Boolean(modelData.danger)
                        readonly property bool isInstant: Boolean(modelData.instant)
                        readonly property bool isZzz: Boolean(modelData.zzz)
                        readonly property bool isArmed: root.armedPowerAction === actKey

                        Layout.preferredHeight: 36
                        Layout.preferredWidth: isArmed ? 72 : 46
                        radius: 11
                        color: isArmed
                            ? (isDanger ? root.lookTheme.coral : root.lookTheme.amber)
                            : (pwrMouse.containsMouse
                                ? (isDanger ? root.lookTheme.tint(root.lookTheme.coral, 0.22) : root.lookTheme.surfaceAlt)
                                : (isDanger ? root.lookTheme.tint(root.lookTheme.coral, 0.12) : root.lookTheme.card))
                        border.width: isArmed ? 0 : 1
                        border.color: isDanger ? root.lookTheme.tint(root.lookTheme.coral, 0.32) : root.lookTheme.glassBorder

                        Behavior on Layout.preferredWidth {
                            NumberAnimation { duration: Kirigami.Units.shortDuration; easing.type: Easing.OutCubic }
                        }

                        Behavior on color {
                            ColorAnimation { duration: Kirigami.Units.shortDuration }
                        }

                        Column {
                            anchors.centerIn: parent
                            spacing: 1

                            Text {
                                visible: pwrBtn.isZzz && !pwrBtn.isArmed
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "Zzz"
                                textFormat: Text.PlainText
                                font.family: root.lookTheme.monoFamily
                                font.pixelSize: 10
                                font.weight: Font.Bold
                                font.italic: true
                                color: root.lookTheme.text
                            }

                            Glyph {
                                visible: !pwrBtn.isZzz || pwrBtn.isArmed
                                anchors.horizontalCenter: parent.horizontalCenter
                                name: pwrBtn.actIcon
                                size: 13
                                color: pwrBtn.isArmed
                                    ? root.lookTheme.obsidian
                                    : (pwrBtn.isDanger ? root.lookTheme.coral : root.lookTheme.text)
                            }

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: pwrBtn.isArmed ? i18n("Confirm?") : pwrBtn.actLabel
                                textFormat: Text.PlainText
                                font.family: root.lookTheme.fontFamily
                                font.pixelSize: 8
                                font.weight: pwrBtn.isArmed ? Font.Bold : Font.Medium
                                color: pwrBtn.isArmed
                                    ? root.lookTheme.obsidian
                                    : (pwrBtn.isDanger ? root.lookTheme.coral : root.lookTheme.subtext)
                            }
                        }

                        MouseArea {
                            id: pwrMouse
                            Accessible.role: Accessible.Button
                            Accessible.name: pwrBtn.isArmed ? i18n("Confirm %1", pwrBtn.actLabel) : pwrBtn.actLabel
                            Accessible.onPressAction: root.triggerPowerButton(pwrBtn.actKey, pwrBtn.isInstant)
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.triggerPowerButton(pwrBtn.actKey, pwrBtn.isInstant)
                        }
                    }
                }
            }
        }
    }
}
