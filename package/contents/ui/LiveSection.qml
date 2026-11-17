pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami
import QtQuick.Layouts

// Quota Island - Canlı Etkinlikler Bölümü.
Item {
    id: root

    property var backend: null
    property Theme theme: null
    property bool compact: false

    Theme {
        id: fallbackTheme
    }

    readonly property Theme lookTheme: root.theme !== null ? root.theme : fallbackTheme

    property var herdrData: ({
        available: false,
        workingCount: 0,
        blockedCount: 0,
        doneCount: 0,
        totalCount: 0,
        agents: []
    })
    property var houraData: ({
        available: false,
        completedSessions: 0,
        focusMinutes: 0,
        focusSeconds: 0,
        pendingTodos: 0,
        completedTodos: 0,
        activeSession: null,
        topTodos: []
    })
    property var powerData: ({
        available: false,
        profile: "balanced",
        profiles: ["performance", "balanced", "power-saver"]
    })
    property var batteryData: ({
        available: false,
        percentage: -1,
        state: "",
        charging: false,
        pluggedIn: false,
        timeRemaining: ""
    })
    property var bluetoothData: ({
        available: false,
        connected: false,
        name: "",
        mac: "",
        isAudio: false,
        battery: -1,
        devices: []
    })

    property string focusedAgentFeedbackId: ""
    property string pendingPowerProfile: ""

    readonly property bool hasBackendLive: Boolean(
        root.backend
        && root.backend.liveData !== undefined
        && root.backend.liveData !== null
        && typeof root.backend.liveData === "object"
    )

    readonly property var effectiveHerdr: (root.hasBackendLive
        && root.backend.liveData.herdr
        && typeof root.backend.liveData.herdr === "object")
        ? root.backend.liveData.herdr : root.herdrData

    readonly property var effectiveHoura: (root.hasBackendLive
        && root.backend.liveData.houra
        && typeof root.backend.liveData.houra === "object")
        ? root.backend.liveData.houra : root.houraData

    readonly property var effectivePower: (root.hasBackendLive
        && root.backend.liveData.power
        && typeof root.backend.liveData.power === "object")
        ? root.backend.liveData.power : root.powerData

    readonly property var effectiveBattery: (root.hasBackendLive
        && root.backend.liveData.battery
        && typeof root.backend.liveData.battery === "object")
        ? root.backend.liveData.battery : root.batteryData

    readonly property var effectiveBluetooth: (root.hasBackendLive
        && root.backend.liveData.bluetooth
        && typeof root.backend.liveData.bluetooth === "object")
        ? root.backend.liveData.bluetooth : root.bluetoothData

    readonly property int workingCount: (root.effectiveHerdr && root.effectiveHerdr.workingCount !== undefined)
                                        ? Math.max(0, Number(root.effectiveHerdr.workingCount)) : 0
    readonly property int blockedCount: (root.effectiveHerdr && root.effectiveHerdr.blockedCount !== undefined)
                                        ? Math.max(0, Number(root.effectiveHerdr.blockedCount)) : 0
    readonly property int doneCount: (root.effectiveHerdr && root.effectiveHerdr.doneCount !== undefined)
                                     ? Math.max(0, Number(root.effectiveHerdr.doneCount)) : 0
    readonly property var agentsList: (root.effectiveHerdr && Array.isArray(root.effectiveHerdr.agents))
                                      ? root.effectiveHerdr.agents : []

    readonly property int houraSessions: (root.effectiveHoura && root.effectiveHoura.completedSessions !== undefined)
                                         ? Math.max(0, Number(root.effectiveHoura.completedSessions)) : 0
    readonly property int houraMinutes: (root.effectiveHoura && root.effectiveHoura.focusMinutes !== undefined)
                                        ? Math.max(0, Number(root.effectiveHoura.focusMinutes)) : 0
    readonly property int houraPendingTodos: (root.effectiveHoura && root.effectiveHoura.pendingTodos !== undefined)
                                             ? Math.max(0, Number(root.effectiveHoura.pendingTodos)) : 0
    readonly property int houraCompletedTodos: (root.effectiveHoura && root.effectiveHoura.completedTodos !== undefined)
                                               ? Math.max(0, Number(root.effectiveHoura.completedTodos)) : 0
    readonly property var houraActiveSession: (root.effectiveHoura && root.effectiveHoura.activeSession
                                               && typeof root.effectiveHoura.activeSession === "object")
                                              ? root.effectiveHoura.activeSession : null
    readonly property var houraTopTodos: (root.effectiveHoura && Array.isArray(root.effectiveHoura.topTodos))
                                         ? root.effectiveHoura.topTodos : []

    readonly property string activePowerProfile: {
        if (root.pendingPowerProfile !== "") {
            return root.pendingPowerProfile;
        }
        const raw = (root.effectivePower && root.effectivePower.profile)
                    ? String(root.effectivePower.profile) : "balanced";
        if (raw === "performance" || raw === "balanced" || raw === "power-saver") {
            return raw;
        }
        return "balanced";
    }

    onEffectivePowerChanged: {
        if (root.pendingPowerProfile !== ""
            && root.effectivePower
            && String(root.effectivePower.profile) === root.pendingPowerProfile) {
            root.pendingPowerProfile = "";
        }
    }

    readonly property bool batteryAvailable: Boolean(root.effectiveBattery && root.effectiveBattery.available)
    readonly property int batteryPct: (root.batteryAvailable && root.effectiveBattery.percentage !== undefined)
                                      ? Math.max(0, Math.min(100, Math.round(Number(root.effectiveBattery.percentage)))) : -1
    readonly property bool batteryCharging: Boolean(root.effectiveBattery && root.effectiveBattery.charging)
    readonly property bool batteryPlugged: Boolean(root.effectiveBattery && (root.effectiveBattery.pluggedIn || root.effectiveBattery.charging))

    readonly property bool btConnected: Boolean(root.effectiveBluetooth && root.effectiveBluetooth.connected)
    readonly property string btName: (root.effectiveBluetooth && root.effectiveBluetooth.name)
                                     ? String(root.effectiveBluetooth.name) : ""
    readonly property int btBattery: (root.effectiveBluetooth && root.effectiveBluetooth.battery !== undefined)
                                     ? Number(root.effectiveBluetooth.battery) : -1

    // Kart görünürlüğü Backend'in algılamasından gelir (araç yok/ayarda kapalı -> gizli).
    readonly property bool herdrShown: Boolean(root.backend && root.backend.herdrShown)
    readonly property bool houraShown: Boolean(root.backend && root.backend.houraShown)
    readonly property bool powerShown: Boolean(root.backend && root.backend.powerShown)
    readonly property bool deviceShown: root.batteryAvailable || root.btConnected
    readonly property bool anyShown: root.herdrShown || root.houraShown || root.powerShown || root.deviceShown

    signal agentFocused(string terminalId)
    signal powerProfileChanged(string profile)

    function formatFocusDuration(minutes: int): string {
        const m = Math.max(0, minutes);
        if (m >= 60) {
            const hrs = Math.floor(m / 60);
            const rem = m % 60;
            return rem > 0 ? i18nc("hours and minutes", "%1h %2m", hrs, rem) : i18nc("hours", "%1 h", hrs);
        }
        return i18nc("minutes", "%1 min", m);
    }

    function agentStatusLabel(status: string): string {
        if (status === "blocked") {
            return i18nc("agent status", "blocked");
        }
        if (status === "working") {
            return i18nc("agent status", "working");
        }
        return i18nc("agent status", "done");
    }

    function agentStatusColor(status: string): color {
        if (status === "blocked") {
            return root.lookTheme.coral;
        }
        if (status === "working") {
            return root.lookTheme.aqua;
        }
        return root.lookTheme.mutedText;
    }

    function _batteryRingColor(): color {
        if (!root.batteryAvailable || root.batteryPct < 0) {
            return root.lookTheme.mutedText;
        }
        if (root.batteryCharging) {
            return root.lookTheme.olive;
        }
        if (root.batteryPct < 20) {
            return root.lookTheme.coral;
        }
        return root.lookTheme.amber;
    }

    function _batteryStateLabel(): string {
        if (!root.batteryAvailable || root.batteryPct < 0) {
            return i18n("On AC power");
        }
        if (root.batteryCharging) {
            return i18n("Charging");
        }
        if (root.batteryPlugged) {
            return i18n("Plugged in");
        }
        if (root.batteryPct < 20) {
            return i18n("Battery low");
        }
        return i18n("On battery");
    }

    function _powerGlyphColor(profileKey: string): color {
        if (profileKey === "performance") {
            return root.lookTheme.orange;
        }
        if (profileKey === "power-saver") {
            return root.lookTheme.olive;
        }
        return root.lookTheme.amber;
    }

    function refresh(): void {
        if (root.backend) {
            root.backend.refreshLive();
        }
    }

    function focusAgent(terminalId: string): void {
        const cleanId = String(terminalId || "").trim();
        if (!/^[A-Za-z0-9_.:@-]{1,64}$/.test(cleanId) || cleanId.startsWith("-")) {
            return;
        }
        root.focusedAgentFeedbackId = cleanId;
        focusFeedbackTimer.restart();

        if (root.backend) {
            root.backend.focusAgent(cleanId);
            root.agentFocused(cleanId);
        }
    }

    function setPowerProfile(profile: string): void {
        const target = String(profile || "").trim();
        if (target !== "performance" && target !== "balanced" && target !== "power-saver") {
            return;
        }
        root.pendingPowerProfile = target;
        powerPreviewHoldTimer.restart();

        if (root.backend) {
            root.backend.setPowerProfile(target);
            root.powerProfileChanged(target);
        }
    }

    Timer {
        id: focusFeedbackTimer
        interval: 1200
        repeat: false
        onTriggered: {
            root.focusedAgentFeedbackId = "";
        }
    }

    Timer {
        id: powerPreviewHoldTimer
        interval: 2500
        repeat: false
        onTriggered: {
            root.pendingPowerProfile = "";
        }
    }

    Component.onCompleted: {
        if (!root.hasBackendLive) {
            root.refresh();
        }
    }

    implicitWidth: 512
    implicitHeight: 314

    Text {
        visible: !root.anyShown
        anchors.centerIn: parent
        text: i18n("No live integrations found")
        textFormat: Text.PlainText
        font.family: root.lookTheme.fontFamily
        font.pixelSize: 12
        color: root.lookTheme.mutedText
    }

    RowLayout {
        anchors.fill: parent
        spacing: 10

        // ====================================================================
        // SOL SÜTUN: Ajan listesi TonalCard (~300px)
        // ====================================================================
        TonalCard {
            visible: root.herdrShown
            Layout.fillWidth: !root.houraShown && !root.powerShown && !root.deviceShown
            Layout.preferredWidth: 300
            Layout.fillHeight: true
            theme: root.lookTheme

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 12

                // Üstte tek satır özet: "1 çalışan · 0 engelli"
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 5

                    Text {
                        text: String(root.workingCount)
                        textFormat: Text.PlainText
                        font.family: root.lookTheme.monoFamily
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        color: root.workingCount > 0 ? root.lookTheme.aqua : root.lookTheme.subtext
                    }

                    Text {
                        text: i18nc("agent count label", "working")
                        textFormat: Text.PlainText
                        font.family: root.lookTheme.fontFamily
                        font.pixelSize: 12
                        color: root.lookTheme.subtext
                    }

                    Text {
                        text: "·"
                        textFormat: Text.PlainText
                        font.family: root.lookTheme.fontFamily
                        font.pixelSize: 12
                        color: root.lookTheme.mutedText
                    }

                    Text {
                        text: String(root.blockedCount)
                        textFormat: Text.PlainText
                        font.family: root.lookTheme.monoFamily
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        color: root.blockedCount > 0 ? root.lookTheme.coral : root.lookTheme.subtext
                    }

                    Text {
                        text: i18nc("agent count label", "blocked")
                        textFormat: Text.PlainText
                        font.family: root.lookTheme.fontFamily
                        font.pixelSize: 12
                        color: root.blockedCount > 0 ? root.lookTheme.coral : root.lookTheme.subtext
                    }

                    Item {
                        Layout.fillWidth: true
                    }
                }

                // Boş durum (en çok 3 sözcük)
                Item {
                    visible: root.agentsList.length === 0
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    Text {
                        anchors.centerIn: parent
                        text: Boolean(root.effectiveHerdr && root.effectiveHerdr.available)
                              ? i18n("No active agents")
                              : i18n("Service unavailable")
                        textFormat: Text.PlainText
                        font.family: root.lookTheme.fontFamily
                        font.pixelSize: 12
                        color: root.lookTheme.mutedText
                    }
                }

                // Ajan satırları (kendi içinde kayar, kaydırma çubuğu yok)
                Flickable {
                    id: agentsFlick
                    visible: root.agentsList.length > 0
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: width
                    contentHeight: agentsListCol.implicitHeight
                    interactive: contentHeight > height + 1
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: agentsListCol
                        width: agentsFlick.width
                        spacing: 4

                        Repeater {
                            model: root.agentsList

                            delegate: Rectangle {
                                id: agentRow

                                required property var modelData
                                required property int index

                                readonly property string termId: agentRow.modelData && agentRow.modelData.id
                                                                 ? String(agentRow.modelData.id) : ""
                                readonly property string whereLabel: agentRow.modelData && agentRow.modelData.where
                                                                     ? String(agentRow.modelData.where) : agentRow.termId
                                readonly property string statusKey: agentRow.modelData && agentRow.modelData.status
                                                                    ? String(agentRow.modelData.status) : "done"
                                readonly property bool justFocused: root.focusedAgentFeedbackId !== ""
                                                                    && root.focusedAgentFeedbackId === agentRow.termId

                                Layout.fillWidth: true
                                Layout.preferredHeight: 34
                                implicitHeight: 34
                                radius: 10
                                activeFocusOnTab: true
                                Accessible.role: Accessible.Button
                                Accessible.name: agentRow.whereLabel
                                color: (agentRowHover.hovered || agentRow.activeFocus)
                                       ? root.lookTheme.cardAlt
                                       : "transparent"

                                Behavior on color {
                                    ColorAnimation { duration: Kirigami.Units.shortDuration }
                                }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 10
                                    spacing: 9

                                    // Sabit 6x6 kutuda durum noktası (yalnız çalışan ajanda opaklık nabzı)
                                    Item {
                                        Layout.preferredWidth: 6
                                        Layout.preferredHeight: 6
                                        implicitWidth: 6
                                        implicitHeight: 6

                                        Rectangle {
                                            id: statusDot
                                            anchors.fill: parent
                                            radius: 3
                                            color: root.agentStatusColor(agentRow.statusKey)

                                            SequentialAnimation on opacity {
                                                loops: Animation.Infinite
                                                running: root.visible && agentRow.statusKey === "working"
                                                onRunningChanged: {
                                                    if (!running) {
                                                        statusDot.opacity = 1.0;
                                                    }
                                                }

                                                NumberAnimation {
                                                    from: 1.0
                                                    to: 0.28
                                                    duration: 800
                                                    easing.type: Easing.InOutSine
                                                }

                                                NumberAnimation {
                                                    from: 0.28
                                                    to: 1.0
                                                    duration: 800
                                                    easing.type: Easing.InOutSine
                                                }
                                            }
                                        }
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: agentRow.whereLabel
                                        textFormat: Text.PlainText
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                        font.family: root.lookTheme.fontFamily
                                        font.pixelSize: 12
                                        color: root.lookTheme.text
                                    }

                                    Text {
                                        text: agentRow.justFocused
                                              ? i18n("focused")
                                              : root.agentStatusLabel(agentRow.statusKey)
                                        textFormat: Text.PlainText
                                        font.family: root.lookTheme.fontFamily
                                        font.pixelSize: 11
                                        color: agentRow.justFocused
                                               ? root.lookTheme.olive
                                               : (agentRow.statusKey === "blocked"
                                                  ? root.lookTheme.coral
                                                  : root.lookTheme.subtext)
                                    }
                                }

                                HoverHandler {
                                    id: agentRowHover
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.focusAgent(agentRow.termId)
                                }

                                Keys.onReturnPressed: root.focusAgent(agentRow.termId)
                                Keys.onSpacePressed: root.focusAgent(agentRow.termId)
                            }
                        }
                    }
                }
            }
        }

        // ====================================================================
        // SAĞ SÜTUN: Üç küçük dikey TonalCard (Odak / Cihaz / Güç)
        // ====================================================================
        ColumnLayout {
            visible: root.houraShown || root.powerShown || root.deviceShown
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 10

            // 1. Odak (44px purple halka + mono süre); Houra yok/kapalıysa gizli
            TonalCard {
                visible: root.houraShown
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: 108
                theme: root.lookTheme

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 14
                    spacing: 12

                    RingGauge {
                        size: 44
                        thickness: 4
                        color: root.lookTheme.purple
                        trackColor: root.lookTheme.track
                        value: (Boolean(root.effectiveHoura && root.effectiveHoura.available) || root.houraMinutes > 0)
                               ? Math.min(1.0, root.houraMinutes / 240.0)
                               : -1

                        Glyph {
                            anchors.centerIn: parent
                            name: "chronometer-symbolic"
                            size: 16
                            color: root.lookTheme.purple
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 2

                        Text {
                            Layout.fillWidth: true
                            text: root.formatFocusDuration(root.houraMinutes)
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            font.family: root.lookTheme.monoFamily
                            font.pixelSize: 16
                            font.weight: Font.DemiBold
                            color: root.lookTheme.text
                        }

                        Text {
                            Layout.fillWidth: true
                            text: i18np("%1 session", "%1 sessions", root.houraSessions)
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            font.family: root.lookTheme.monoFamily
                            font.pixelSize: 11
                            color: root.lookTheme.subtext
                        }
                    }
                }
            }

            // 2. Cihaz (44px pil halkası + tek satır; BT bağlıysa gösterilir)
            TonalCard {
                visible: root.deviceShown
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: 108
                theme: root.lookTheme

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 14
                    spacing: 12

                    RingGauge {
                        size: 44
                        thickness: 4
                        value: (root.batteryAvailable && root.batteryPct >= 0) ? (root.batteryPct / 100.0) : -1
                        color: root._batteryRingColor()
                        trackColor: root.lookTheme.track

                        Row {
                            visible: root.batteryAvailable && root.batteryPct >= 0
                            anchors.centerIn: parent
                            spacing: 1

                            Text {
                                id: batNum
                                text: root.batteryPct >= 0 ? String(root.batteryPct) : "0"
                                textFormat: Text.PlainText
                                font.family: root.lookTheme.monoFamily
                                font.pixelSize: 11
                                font.weight: Font.Bold
                                color: (root.batteryPct < 20 && !root.batteryCharging)
                                       ? root.lookTheme.coral
                                       : root.lookTheme.text
                            }

                            Text {
                                anchors.baseline: batNum.baseline
                                text: "%"
                                textFormat: Text.PlainText
                                font.family: root.lookTheme.monoFamily
                                font.pixelSize: 8
                                color: root.lookTheme.mutedText
                            }
                        }

                        Glyph {
                            visible: !root.batteryAvailable || root.batteryPct < 0
                            anchors.centerIn: parent
                            name: "ac-adapter-symbolic"
                            size: 16
                            color: root.lookTheme.subtext
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 3

                        Text {
                            Layout.fillWidth: true
                            text: root._batteryStateLabel()
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            font.family: root.lookTheme.fontFamily
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            color: root.lookTheme.text
                        }

                        RowLayout {
                            visible: root.btConnected
                            Layout.fillWidth: true
                            spacing: 5

                            Glyph {
                                name: "audio-headphones-symbolic"
                                size: 12
                                color: root.lookTheme.aqua
                            }

                            Text {
                                Layout.fillWidth: true
                                text: root.btName
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                maximumLineCount: 1
                                font.family: root.lookTheme.fontFamily
                                font.pixelSize: 11
                                color: root.lookTheme.subtext
                            }

                            Text {
                                visible: root.btBattery >= 0
                                text: String(Math.max(0, Math.min(100, root.btBattery))) + "%"
                                textFormat: Text.PlainText
                                font.family: root.lookTheme.monoFamily
                                font.pixelSize: 10
                                color: root.lookTheme.mutedText
                            }
                        }
                    }
                }
            }

            // 3. Güç (3 glif düğmesi, etiketsiz, seçili cardAlt + renkli glif)
            TonalCard {
                visible: root.powerShown
                Layout.fillWidth: true
                Layout.fillHeight: !root.houraShown && !root.deviceShown
                Layout.preferredHeight: 78
                theme: root.lookTheme

                RowLayout {
                    id: powerRow
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 8

                    readonly property var profileOptions: [
                        { key: "performance", icon: "power-profile-performance-symbolic", name: i18n("Performance") },
                        { key: "balanced", icon: "power-profile-balanced-symbolic", name: i18n("Balanced") },
                        { key: "power-saver", icon: "power-profile-power-saver-symbolic", name: i18n("Power Saver") }
                    ]

                    Repeater {
                        model: powerRow.profileOptions

                        delegate: Rectangle {
                            id: segBtn

                            required property var modelData
                            required property int index

                            readonly property string profileKey: segBtn.modelData && segBtn.modelData.key
                                                                 ? String(segBtn.modelData.key) : "balanced"
                            readonly property string profileIcon: segBtn.modelData && segBtn.modelData.icon
                                                                  ? String(segBtn.modelData.icon) : "power-profile-balanced-symbolic"
                            readonly property string profileName: segBtn.modelData && segBtn.modelData.name
                                                                  ? String(segBtn.modelData.name) : i18n("Balanced")
                            readonly property bool selected: root.activePowerProfile === segBtn.profileKey

                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.preferredWidth: 1
                            radius: 14
                            activeFocusOnTab: true
                            Accessible.role: Accessible.Button
                            Accessible.name: segBtn.profileName
                            color: segBtn.selected
                                   ? root.lookTheme.cardAlt
                                   : ((segHover.hovered || segBtn.activeFocus)
                                      ? root.lookTheme.tint(root.lookTheme.text, 0.05)
                                      : "transparent")

                            Behavior on color {
                                ColorAnimation { duration: Kirigami.Units.shortDuration }
                            }

                            Glyph {
                                anchors.centerIn: parent
                                name: segBtn.profileIcon
                                size: 18
                                color: segBtn.selected
                                       ? root._powerGlyphColor(segBtn.profileKey)
                                       : (segHover.hovered ? root.lookTheme.text : root.lookTheme.subtext)
                            }

                            HoverHandler {
                                id: segHover
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.setPowerProfile(segBtn.profileKey)
                            }

                            Keys.onReturnPressed: root.setPowerProfile(segBtn.profileKey)
                            Keys.onSpacePressed: root.setPowerProfile(segBtn.profileKey)
                            Keys.onLeftPressed: {
                                const order = ["performance", "balanced", "power-saver"];
                                const curIdx = order.indexOf(segBtn.profileKey);
                                if (curIdx > 0) {
                                    root.setPowerProfile(order[curIdx - 1]);
                                }
                            }
                            Keys.onRightPressed: {
                                const order = ["performance", "balanced", "power-saver"];
                                const curIdx = order.indexOf(segBtn.profileKey);
                                if (curIdx >= 0 && curIdx < order.length - 1) {
                                    root.setPowerProfile(order[curIdx + 1]);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
