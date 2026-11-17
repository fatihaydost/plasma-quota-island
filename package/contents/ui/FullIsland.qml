pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami
import QtQuick.Layouts

// Quota Island: sabit boyutlu popup kabuğu (ölçü Theme.popupWidth/popupHeight).
FocusScope {
    id: root

    property var backend: null
    property Theme theme: null
    property var plasmoidItem: null
    property int volumeStep: 5
    property int currentTab: 0
    property int requestedTab: -1

    signal closeRequested()

    Theme {
        id: fallbackTheme
    }

    readonly property Theme lookTheme: root.theme !== null ? root.theme : fallbackTheme

    readonly property bool mediaPlaying: Boolean(root.backend && root.backend.mediaAvailable && root.backend.playbackStatus === "Playing")
    readonly property int currentVolume: (root.backend && root.backend.volume !== undefined)
                                         ? Math.max(0, Math.min(150, Math.round(Number(root.backend.volume)))) : 0
    readonly property bool currentMuted: Boolean(root.backend && root.backend.muted)
    readonly property bool micMuted: Boolean(root.backend && root.backend.sourceMuted)

    // Hiç sağlayıcı görünmüyorsa Kotalar sekmesi (indeks 2) gizlenir; indeksler sabit kalır.
    readonly property bool quotaTabHidden: Boolean(root.backend && root.backend.quotasLoaded && !root.backend.anyQuotaShown)
    readonly property int visibleTabCount: root.tabCount - (root.quotaTabHidden ? 1 : 0)

    function isTabHidden(idx: int): bool {
        return idx === 2 && root.quotaTabHidden;
    }

    // Gizli sekmeler atlanarak sekmenin görsel sütun sırası
    function visualTabPos(idx: int): int {
        return (root.quotaTabHidden && idx > 2) ? idx - 1 : idx;
    }

    onQuotaTabHiddenChanged: {
        if (root.quotaTabHidden && root.currentTab === 2) {
            root.switchTab(0);
        }
    }

    readonly property int liveWorkingCount: (root.backend && root.backend.herdrWorkingCount !== undefined)
                                            ? Math.max(0, Number(root.backend.herdrWorkingCount))
                                            : liveSection.workingCount
    readonly property int liveBlockedCount: (root.backend && root.backend.herdrBlockedCount !== undefined)
                                            ? Math.max(0, Number(root.backend.herdrBlockedCount))
                                            : liveSection.blockedCount
    readonly property int liveHouraMinutes: liveSection.houraMinutes
    readonly property string livePowerProfile: liveSection.activePowerProfile
    readonly property int shelfItemCount: shelfSection.itemCount

    readonly property var tabTitles: [i18nc("@title:tab", "Overview"), i18nc("@title:tab", "Media & Audio"), i18nc("@title:tab", "Quotas"), i18nc("@title:tab", "Live"), i18nc("@title:tab", "Shelf")]
    readonly property var tabIcons: [
        "view-grid-symbolic",
        "emblem-music-symbolic",
        "chronometer-symbolic",
        "utilities-terminal-symbolic",
        "folder-symbolic"
    ]
    readonly property int tabCount: Math.max(1, root.tabTitles.length)

    readonly property int targetContentHeight: root.lookTheme.popupHeight

    focus: true

    // Sabit 540x384: sekme değişiminde pencere boyutu 1px oynamaz
    implicitWidth: root.lookTheme.popupWidth
    implicitHeight: root.lookTheme.popupHeight

    Layout.minimumWidth: root.lookTheme.popupWidth
    Layout.preferredWidth: root.lookTheme.popupWidth
    Layout.maximumWidth: root.lookTheme.popupWidth
    Layout.minimumHeight: root.lookTheme.popupHeight
    Layout.preferredHeight: root.lookTheme.popupHeight
    Layout.maximumHeight: root.lookTheme.popupHeight

    onRequestedTabChanged: {
        if (root.requestedTab >= 0 && root.requestedTab < root.tabCount) {
            root.switchTab(root.requestedTab);
        }
    }

    function powerLabelTr(profile: string): string {
        if (profile === "performance") {
            return i18n("Performance");
        }
        if (profile === "power-saver") {
            return i18n("Power Saver");
        }
        return i18n("Balanced");
    }

    function tabDisplayTitle(_idx: int, baseTitle: string): string {
        return baseTitle;
    }

    function switchTab(idx: int): void {
        const lastIdx = Math.max(0, root.tabCount - 1);
        let bounded = Math.max(0, Math.min(lastIdx, idx));
        if (root.isTabHidden(bounded)) {
            bounded = Math.max(0, Math.min(lastIdx, bounded + (bounded >= root.currentTab ? 1 : -1)));
        }
        if (root.currentTab === bounded) {
            return;
        }
        root.currentTab = bounded;
        if (bounded === 2 && root.backend && typeof root.backend.refreshQuotas === "function") {
            root.backend.refreshQuotas(false);
        } else if (bounded === 3) {
            liveSection.refresh();
        } else if (bounded === 4) {
            shelfSection.refresh();
        }
    }

    function openLiveTab(): void {
        root.switchTab(3);
        liveSection.refresh();
    }

    function openShelfTab(): void {
        root.switchTab(4);
        shelfSection.refresh();
    }

    function addShelfItems(rawValues: var): void {
        root.switchTab(4);
        shelfSection.addItems(rawValues);
    }

    function focusTabButton(idx: int): void {
        const lastIdx = Math.max(0, root.tabCount - 1);
        const bounded = Math.max(0, Math.min(lastIdx, idx));
        root.switchTab(bounded);
        const item = tabRepeater.itemAt(root.currentTab);
        if (item) {
            item.forceActiveFocus();
        }
    }

    function _collapseParent(node: var): void {
        let cur = node;
        while (cur) {
            if (cur.expanded !== undefined) {
                cur.expanded = false;
                return;
            }
            cur = cur.parent;
        }
    }

    function closePopup(): void {
        root.closeRequested();
        if (root.plasmoidItem && root.plasmoidItem.expanded !== undefined) {
            root.plasmoidItem.expanded = false;
            return;
        }
        root._collapseParent(root.parent);
    }

    function triggerRefreshAll(): void {
        if (root.backend) {
            if (typeof root.backend.refreshStatus === "function") {
                root.backend.refreshStatus();
            }
            if (typeof root.backend.refreshQuotas === "function") {
                root.backend.refreshQuotas(true);
            }
        }
        liveSection.refresh();
        shelfSection.refresh();
    }

    onVisibleChanged: {
        if (root.visible) {
            liveSection.refresh();
            shelfSection.refresh();
            const firstTab = tabRepeater.itemAt(root.currentTab);
            if (firstTab) {
                firstTab.forceActiveFocus();
            } else {
                root.forceActiveFocus();
            }
        }
    }

    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Escape) {
            root.closePopup();
            event.accepted = false;
        }
    }

    IslandSurface {
        id: islandFrame
        anchors.fill: parent
        theme: root.lookTheme
        radius: 24
        highlighted: popupDropArea.containsDrag
        // Cam: gövde saydam; Plasma'nın kendi bulanık yarı saydam popup zemini görünür.
        sheen: false
        color: "transparent"
        border.width: 0
        rimColor: popupDropArea.containsDrag ? root.lookTheme.rimStrong : "transparent"
        clip: true

        DropArea {
            id: popupDropArea
            anchors.fill: parent
            enabled: root.currentTab !== 4
            onEntered: (drag) => {
                drag.acceptProposedAction();
            }
            onDropped: (drop) => {
                let collected = [];
                if (drop.hasUrls && drop.urls && drop.urls.length > 0) {
                    for (let i = 0; i < drop.urls.length; ++i) {
                        const u = String(drop.urls[i]).trim();
                        if (u !== "") {
                            collected.push(u);
                        }
                    }
                } else if (drop.hasText && drop.text && String(drop.text).trim() !== "") {
                    collected.push(String(drop.text));
                }
                if (collected.length > 0) {
                    root.addShelfItems(collected);
                    drop.acceptProposedAction();
                }
            }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 8

            // Sekme çubuğu (zeminsiz 5 eşit sütun + 28x3 amber gösterge)
            Item {
                id: tabBar
                Layout.fillWidth: true
                Layout.preferredHeight: 50

                readonly property real colWidth: width / Math.max(1, root.visibleTabCount)

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    onWheel: (wheel) => {
                        if (wheel.angleDelta.y < 0) {
                            root.switchTab(root.currentTab + 1);
                            wheel.accepted = true;
                        } else if (wheel.angleDelta.y > 0) {
                            root.switchTab(root.currentTab - 1);
                            wheel.accepted = true;
                        }
                    }
                }

                Row {
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 43
                    spacing: 0

                    Repeater {
                        id: tabRepeater
                        model: root.tabTitles

                        delegate: Item {
                            id: tabBtn

                            required property var modelData
                            required property int index

                            readonly property bool isSelected: root.currentTab === tabBtn.index
                            readonly property bool showLiveDot: tabBtn.index === 3 && (root.liveBlockedCount > 0 || root.liveWorkingCount > 0)
                            readonly property string iconName: tabBtn.index < root.tabIcons.length
                                                               ? String(root.tabIcons[tabBtn.index])
                                                               : "view-grid-symbolic"

                            visible: !root.isTabHidden(tabBtn.index)
                            width: visible ? tabBar.colWidth : 0
                            height: 43
                            activeFocusOnTab: visible
                            Accessible.role: Accessible.PageTab
                            Accessible.name: String(tabBtn.modelData)

                            Keys.onPressed: (event) => {
                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                    root.switchTab(tabBtn.index);
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Left) {
                                    root.focusTabButton((root.currentTab + root.tabCount - 1) % root.tabCount);
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Right) {
                                    root.focusTabButton((root.currentTab + 1) % root.tabCount);
                                    event.accepted = true;
                                }
                            }

                            Rectangle {
                                anchors.fill: parent
                                anchors.leftMargin: 6
                                anchors.rightMargin: 6
                                radius: 12
                                color: root.lookTheme.cardAlt
                                opacity: tabBtn.activeFocus
                                         ? 0.85
                                         : ((tabMouse.containsMouse && !tabBtn.isSelected) ? 0.5 : 0.0)

                                Behavior on opacity {
                                    NumberAnimation { duration: Kirigami.Units.shortDuration }
                                }
                            }

                            Column {
                                anchors.centerIn: parent
                                spacing: 3

                                Item {
                                    width: 16
                                    height: 16
                                    anchors.horizontalCenter: parent.horizontalCenter

                                    Glyph {
                                        anchors.centerIn: parent
                                        name: tabBtn.iconName
                                        size: 16
                                        color: tabBtn.isSelected
                                               ? root.lookTheme.amber
                                               : (tabMouse.containsMouse ? root.lookTheme.text : root.lookTheme.subtext)
                                    }

                                    Rectangle {
                                        visible: tabBtn.showLiveDot
                                        x: 13
                                        y: -2
                                        width: 5
                                        height: 5
                                        radius: 2.5
                                        color: root.liveBlockedCount > 0 ? root.lookTheme.coral : root.lookTheme.aqua
                                    }
                                }

                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: Math.min(tabBtn.width - 8, implicitWidth)
                                    horizontalAlignment: Text.AlignHCenter
                                    text: root.tabDisplayTitle(tabBtn.index, String(tabBtn.modelData))
                                    textFormat: Text.PlainText
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                    font.family: root.lookTheme.fontFamily
                                    font.pixelSize: 11
                                    font.weight: tabBtn.isSelected ? Font.DemiBold : Font.Medium
                                    color: tabBtn.isSelected
                                           ? root.lookTheme.amber
                                           : (tabMouse.containsMouse ? root.lookTheme.text : root.lookTheme.subtext)

                                    Behavior on color {
                                        ColorAnimation { duration: Kirigami.Units.shortDuration }
                                    }
                                }
                            }

                            MouseArea {
                                id: tabMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: (mouse) => {
                                    mouse.accepted = true;
                                    tabBtn.forceActiveFocus();
                                    root.switchTab(tabBtn.index);
                                }
                                onWheel: (wheel) => {
                                    if (wheel.angleDelta.y < 0) {
                                        root.switchTab(root.currentTab + 1);
                                        wheel.accepted = true;
                                    } else if (wheel.angleDelta.y > 0) {
                                        root.switchTab(root.currentTab - 1);
                                        wheel.accepted = true;
                                    }
                                }
                            }
                        }
                    }
                }

                // 3px yüksek, 28px geniş, tam yuvarlak amber gösterge (200ms OutCubic)
                Rectangle {
                    x: Math.round(tabBar.colWidth * root.visualTabPos(root.currentTab) + (tabBar.colWidth - width) / 2)
                    anchors.bottom: parent.bottom
                    width: 28
                    height: 3
                    radius: 1.5
                    color: root.lookTheme.amber

                    Behavior on x {
                        NumberAnimation {
                            duration: Kirigami.Units.longDuration
                            easing.type: Easing.OutCubic
                        }
                    }
                }
            }

            // Sabit içerik alanı (512 x 298): 5 sekme yalnız 140ms opaklık ile çapraz solar
            Item {
                id: contentArea
                Layout.fillWidth: true
                Layout.fillHeight: true

                // Sekme 0: Panel (3 satırlı kontrol merkezi: Clock+Weather | Calendar | LoadCard / Vinyl Media / Quick Toggles + Power)
                Item {
                    anchors.fill: parent
                    enabled: root.currentTab === 0
                    opacity: root.currentTab === 0 ? 1.0 : 0.0
                    visible: opacity > 0.001

                    Behavior on opacity {
                        NumberAnimation { duration: Kirigami.Units.shortDuration }
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 10

                        // Row 1: DashClock (Time+Weather) | DashCalendar | LoadCard (CPU/RAM/GPU/SSD + Power Profile)
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 170
                            spacing: 10

                            TonalCard {
                                theme: root.lookTheme
                                Layout.preferredWidth: 152
                                Layout.fillHeight: true

                                DashClock {
                                    anchors.fill: parent
                                    backend: root.backend
                                    theme: root.lookTheme
                                }
                            }

                            TonalCard {
                                theme: root.lookTheme
                                Layout.preferredWidth: 196
                                Layout.fillHeight: true

                                DashCalendar {
                                    anchors.fill: parent
                                    backend: root.backend
                                    theme: root.lookTheme
                                }
                            }

                            // System Load & Power Profile Card
                            TonalCard {
                                theme: root.lookTheme
                                Layout.fillWidth: true
                                Layout.fillHeight: true

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 10
                                    spacing: 5

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 4

                                        Text {
                                            text: i18n("SYSTEM LOAD")
                                            textFormat: Text.PlainText
                                            font.family: root.lookTheme ? root.lookTheme.monoFamily : "JetBrains Mono"
                                            font.pixelSize: 9
                                            font.weight: Font.Bold
                                            font.letterSpacing: 0.6
                                            color: root.lookTheme ? root.lookTheme.subtext : "#a89984"
                                        }

                                        Item { Layout.fillWidth: true }

                                        Text {
                                            text: root.backend && root.backend.cpuTemp > 0 ? (root.backend.cpuTemp + "°C") : ""
                                            textFormat: Text.PlainText
                                            font.family: root.lookTheme ? root.lookTheme.monoFamily : "JetBrains Mono"
                                            font.pixelSize: 9
                                            font.weight: Font.DemiBold
                                            color: root.backend && root.backend.cpuTemp >= 80
                                                ? (root.lookTheme ? root.lookTheme.danger : "#da4453")
                                                : (root.lookTheme ? root.lookTheme.accent : "#3daee9")
                                        }
                                    }

                                    // 4 Metric Bars: CPU, RAM, GPU, SSD
                                    Repeater {
                                        model: [
                                            {
                                                label: "CPU",
                                                pct: root.backend ? root.backend.cpuPct : 0,
                                                meta: (root.backend ? root.backend.cpuPct : 0) + "%" + (root.backend && root.backend.cpuTemp > 0 ? " · " + root.backend.cpuTemp + "°" : ""),
                                                barColor: root.lookTheme ? root.lookTheme.accent : "#3daee9"
                                            },
                                            {
                                                label: "RAM",
                                                pct: root.backend ? root.backend.ramPct : 0,
                                                meta: (root.backend ? Number(root.backend.ramUsedGb).toFixed(1) : "0.0") + "G · " + (root.backend ? root.backend.ramPct : 0) + "%",
                                                barColor: root.lookTheme ? root.lookTheme.purple : "#b16286"
                                            },
                                            {
                                                label: "GPU",
                                                pct: root.backend ? root.backend.gpuPct : 0,
                                                meta: (root.backend ? root.backend.gpuPct : 0) + "%" + (root.backend && root.backend.gpuTemp > 0 ? " · " + root.backend.gpuTemp + "°" : ""),
                                                barColor: root.lookTheme ? root.lookTheme.positive : "#27ae60"
                                            },
                                            {
                                                label: "SSD",
                                                pct: root.backend ? root.backend.diskPct : 0,
                                                meta: (root.backend ? root.backend.diskPct : 0) + "% · " + (root.backend ? Math.round(root.backend.diskUsedGb) : 0) + "G",
                                                barColor: root.lookTheme ? root.lookTheme.warning : "#f67400"
                                            }
                                        ]

                                        delegate: ColumnLayout {
                                            id: metricRow
                                            required property var modelData
                                            Layout.fillWidth: true
                                            spacing: 2

                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: 4

                                                Text {
                                                    text: String(metricRow.modelData.label)
                                                    textFormat: Text.PlainText
                                                    font.family: root.lookTheme ? root.lookTheme.monoFamily : "JetBrains Mono"
                                                    font.pixelSize: 9
                                                    font.weight: Font.Bold
                                                    color: root.lookTheme ? root.lookTheme.text : "#ebdbb2"
                                                }

                                                Item { Layout.fillWidth: true }

                                                Text {
                                                    text: String(metricRow.modelData.meta)
                                                    textFormat: Text.PlainText
                                                    font.family: root.lookTheme ? root.lookTheme.monoFamily : "JetBrains Mono"
                                                    font.pixelSize: 9
                                                    font.weight: Font.Medium
                                                    color: root.lookTheme ? root.lookTheme.subtext : "#a89984"
                                                }
                                            }

                                            Rectangle {
                                                Layout.fillWidth: true
                                                Layout.preferredHeight: 4
                                                radius: 2
                                                color: root.lookTheme ? root.lookTheme.track : "#22ffffff"

                                                Rectangle {
                                                    width: Math.max(3, Math.round(parent.width * Math.max(0, Math.min(100, Number(metricRow.modelData.pct || 0))) / 100.0))
                                                    height: parent.height
                                                    radius: 2
                                                    color: metricRow.modelData.barColor

                                                    Behavior on width {
                                                        NumberAnimation { duration: Kirigami.Units.longDuration; easing.type: Easing.OutCubic }
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    Item { Layout.fillHeight: true }

                                    // Power Profile Selector Strip (Performans / Dengeli / Tasarruf); powerprofilesctl yoksa gizli
                                    RowLayout {
                                        visible: Boolean(root.backend && root.backend.powerShown)
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 22
                                        spacing: 3

                                        Repeater {
                                            model: [
                                                { key: "performance", label: i18nc("short for performance power profile", "Perf") },
                                                { key: "balanced",    label: i18nc("short for balanced power profile", "Bal") },
                                                { key: "power-saver", label: i18nc("short for power saver profile", "Eco") }
                                            ]

                                            delegate: Rectangle {
                                                id: profChip
                                                required property var modelData
                                                readonly property bool isActive: (root.backend ? root.backend.powerProfile : "balanced") === String(modelData.key)
                                                Layout.fillWidth: true
                                                Layout.fillHeight: true
                                                radius: 6
                                                color: isActive
                                                    ? (root.lookTheme ? Qt.rgba(root.lookTheme.accent.r, root.lookTheme.accent.g, root.lookTheme.accent.b, 0.24) : "#333daee9")
                                                    : (profArea.containsMouse
                                                        ? (root.lookTheme ? root.lookTheme.cardAlt : "#3c3836")
                                                        : (root.lookTheme ? root.lookTheme.card : "#12ffffff"))
                                                border.width: isActive ? 1 : 0
                                                border.color: root.lookTheme ? Qt.rgba(root.lookTheme.accent.r, root.lookTheme.accent.g, root.lookTheme.accent.b, 0.50) : "#803daee9"

                                                Text {
                                                    anchors.centerIn: parent
                                                    text: String(profChip.modelData.label)
                                                    textFormat: Text.PlainText
                                                    font.family: root.lookTheme ? root.lookTheme.fontFamily : "Inter"
                                                    font.pixelSize: 9
                                                    font.weight: profChip.isActive ? Font.Bold : Font.Medium
                                                    color: profChip.isActive
                                                        ? (root.lookTheme ? root.lookTheme.text : "#ebdbb2")
                                                        : (root.lookTheme ? root.lookTheme.subtext : "#a89984")
                                                }

                                                MouseArea {
                                                    id: profArea
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        if (root.backend) {
                                                            root.backend.setPowerProfile(String(profChip.modelData.key))
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Row 2: Vinyl + WaveBars Equalizer Media Player
                        TonalCard {
                            theme: root.lookTheme
                            Layout.fillWidth: true
                            Layout.preferredHeight: 108

                            DashMedia {
                                anchors.fill: parent
                                backend: root.backend
                                theme: root.lookTheme
                            }
                        }

                        // Row 3: Quick Toggles (Wi-Fi/BT/Coffee/DND) + Quota Chips + Power Strip
                        DashResources {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 92
                            backend: root.backend
                            theme: root.lookTheme
                            onTabRequested: (i) => root.switchTab(i)
                        }
                    }
                }

                // Sekme 1: Medya & Ses (iki TonalCard yan yana)
                Item {
                    anchors.fill: parent
                    enabled: root.currentTab === 1
                    opacity: root.currentTab === 1 ? 1.0 : 0.0
                    visible: opacity > 0.001

                    Behavior on opacity {
                        NumberAnimation { duration: Kirigami.Units.shortDuration }
                    }

                    RowLayout {
                        anchors.fill: parent
                        spacing: 10

                        TonalCard {
                            theme: root.lookTheme
                            Layout.preferredWidth: 248
                            Layout.fillHeight: true

                            MediaSection {
                                anchors.fill: parent
                                backend: root.backend
                                theme: root.lookTheme
                                compact: false
                            }
                        }

                        TonalCard {
                            theme: root.lookTheme
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            AudioSection {
                                anchors.fill: parent
                                backend: root.backend
                                theme: root.lookTheme
                                compact: false
                                volumeStep: root.volumeStep
                            }
                        }
                    }
                }

                // Sekme 2: Kotalar
                Item {
                    anchors.fill: parent
                    enabled: root.currentTab === 2
                    opacity: root.currentTab === 2 ? 1.0 : 0.0
                    visible: opacity > 0.001

                    Behavior on opacity {
                        NumberAnimation { duration: Kirigami.Units.shortDuration }
                    }

                    QuotaSection {
                        anchors.fill: parent
                        backend: root.backend
                        theme: root.lookTheme
                        compact: false
                    }
                }

                // Sekme 3: Canlı
                Item {
                    anchors.fill: parent
                    enabled: root.currentTab === 3
                    opacity: root.currentTab === 3 ? 1.0 : 0.0
                    visible: opacity > 0.001

                    Behavior on opacity {
                        NumberAnimation { duration: Kirigami.Units.shortDuration }
                    }

                    LiveSection {
                        id: liveSection
                        anchors.fill: parent
                        backend: root.backend
                        theme: root.lookTheme
                        compact: false
                    }
                }

                // Sekme 4: Raf
                Item {
                    anchors.fill: parent
                    enabled: root.currentTab === 4
                    opacity: root.currentTab === 4 ? 1.0 : 0.0
                    visible: opacity > 0.001

                    Behavior on opacity {
                        NumberAnimation { duration: Kirigami.Units.shortDuration }
                    }

                    ShelfSection {
                        id: shelfSection
                        anchors.fill: parent
                        backend: root.backend
                        theme: root.lookTheme
                        compact: false
                    }
                }
            }
        }
    }
}
