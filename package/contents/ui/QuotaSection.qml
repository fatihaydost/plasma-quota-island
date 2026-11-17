pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// Quota Island - Sağlayıcı kotaları bölümü (Claude, AGY, Codex).
// Yalnız açık ve kimliği bulunan sağlayıcıların kartı görünür (Backend.*Shown).
Item {
    id: root

    property var backend: null
    property Theme theme: null
    property bool compact: false

    Theme {
        id: fallbackTheme
    }

    readonly property Theme lookTheme: root.theme !== null ? root.theme : fallbackTheme

    readonly property bool claudeShown: Boolean(root.backend && root.backend.claudeShown)
    readonly property bool agyShown: Boolean(root.backend && root.backend.agyShown)
    readonly property bool codexShown: Boolean(root.backend && root.backend.codexShown)

    readonly property string updatedAtText: (root.backend && root.backend.quotasUpdatedAt)
                                            ? String(root.backend.quotasUpdatedAt) : ""
    readonly property bool quotasLoading: Boolean(root.backend && root.backend.quotasLoading)

    function bucketUsed(bucket: var): int {
        if (bucket && typeof bucket === "object" && bucket.usedPct !== undefined && bucket.usedPct !== null) {
            const n = Math.round(Number(bucket.usedPct));
            if (isFinite(n)) {
                if (n < 0) {
                    return -1;
                }
                return Math.max(0, Math.min(100, n));
            }
        }
        return -1;
    }

    function bucketRemaining(bucket: var, usedVal: int): int {
        if (usedVal < 0) {
            return -1;
        }
        if (bucket && typeof bucket === "object" && bucket.remainingPct !== undefined && bucket.remainingPct !== null) {
            const n = Math.round(Number(bucket.remainingPct));
            if (isFinite(n) && n >= 0) {
                return Math.max(0, Math.min(100, n));
            }
        }
        return Math.max(0, Math.min(100, 100 - usedVal));
    }


    function _formatDayTime(isoStr: string): string {
        if (isoStr === "") {
            return "";
        }
        const dt = new Date(isoStr);
        if (isNaN(dt.getTime())) {
            return "";
        }
        const hh = dt.getHours() < 10 ? ("0" + String(dt.getHours())) : String(dt.getHours());
        const mm = dt.getMinutes() < 10 ? ("0" + String(dt.getMinutes())) : String(dt.getMinutes());
        return Qt.locale().dayName(dt.getDay(), Locale.ShortFormat) + " " + hh + ":" + mm;
    }

    // Sıfırlanmaya kalan süre; Python'un resetInHuman metni yerine resetsAt'tan yerelleştirilmiş üretilir.
    function _humanResetIn(bucket: var): string {
        const iso = (bucket && bucket.resetsAt) ? String(bucket.resetsAt) : "";
        const dt = iso !== "" ? new Date(iso) : null;
        if (!dt || isNaN(dt.getTime())) {
            return "";
        }
        const sec = Math.max(0, Math.round((dt.getTime() - Date.now()) / 1000));
        if (sec >= 86400) {
            return i18nc("days and hours until reset", "%1d %2h", Math.floor(sec / 86400), Math.floor((sec % 86400) / 3600));
        }
        if (sec >= 3600) {
            return i18nc("hours and minutes until reset", "%1h %2m", Math.floor(sec / 3600), Math.floor((sec % 3600) / 60));
        }
        return i18nc("minutes until reset", "%1 min", sec > 0 ? Math.max(1, Math.ceil(sec / 60)) : 0);
    }

    function _shortReset5h(bucket: var): string {
        if (!bucket || typeof bucket !== "object") {
            return "";
        }
        const human = root._humanResetIn(bucket);
        if (human !== "") {
            return human;
        }
        const iso = bucket.resetsAt ? String(bucket.resetsAt) : "";
        const dt = iso !== "" ? new Date(iso) : null;
        if (dt && !isNaN(dt.getTime())) {
            const hh = dt.getHours() < 10 ? ("0" + String(dt.getHours())) : String(dt.getHours());
            const mm = dt.getMinutes() < 10 ? ("0" + String(dt.getMinutes())) : String(dt.getMinutes());
            return hh + ":" + mm;
        }
        return "";
    }

    function _shortReset7d(bucket: var): string {
        if (!bucket || typeof bucket !== "object") {
            return "";
        }
        const iso = bucket.resetsAt ? String(bucket.resetsAt) : "";
        const dayTime = root._formatDayTime(iso);
        if (dayTime !== "") {
            return dayTime;
        }
        const human = root._humanResetIn(bucket);
        if (human !== "") {
            return human;
        }
        return "";
    }



    function triggerRefreshQuotas(): void {
        if (!root.quotasLoading && root.backend && typeof root.backend.refreshQuotas === "function") {
            root.backend.refreshQuotas(true);
        }
    }

    implicitWidth: 512
    implicitHeight: 314

    component MonoPct: Row {
        id: pctRoot

        property int pct: -1
        property int numberSize: 11
        property int weight: Font.DemiBold
        property color numberColor: pctTheme.text
        required property Theme pctTheme

        spacing: 1

        Text {
            id: pctNumText
            text: pctRoot.pct >= 0 ? String(Math.max(0, Math.min(100, pctRoot.pct))) : "—"
            textFormat: Text.PlainText
            font.family: pctRoot.pctTheme.monoFamily
            font.pixelSize: pctRoot.numberSize
            font.weight: pctRoot.weight
            color: pctRoot.pct >= 0 ? pctRoot.numberColor : pctRoot.pctTheme.mutedText
        }

        Text {
            visible: pctRoot.pct >= 0
            anchors.baseline: pctNumText.baseline
            text: "%"
            textFormat: Text.PlainText
            font.family: pctRoot.pctTheme.monoFamily
            font.pixelSize: Math.max(8, pctRoot.numberSize - 3)
            font.weight: Font.Medium
            color: pctRoot.pctTheme.mutedText
        }
    }

    // Sade pencere satırı: "5sa  10%  2s 4dk"
    component WindowLine: RowLayout {
        id: winLine

        property string tag: ""
        property int usedPct: -1
        property string resetText: ""
        required property Theme rowTheme

        Layout.fillWidth: true
        spacing: 8

        Text {
            Layout.preferredWidth: 28
            text: winLine.tag
            textFormat: Text.PlainText
            font.family: winLine.rowTheme.monoFamily
            font.pixelSize: 11
            color: winLine.rowTheme.subtext
        }

        MonoPct {
            pct: winLine.usedPct
            numberSize: 11
            weight: Font.DemiBold
            numberColor: winLine.rowTheme.text
            pctTheme: winLine.rowTheme
        }

        Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignRight
            text: winLine.usedPct >= 0 ? winLine.resetText : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            maximumLineCount: 1
            font.family: winLine.rowTheme.monoFamily
            font.pixelSize: 11
            color: winLine.rowTheme.subtext
        }
    }

    // Ek kova: ince 3px çubuk + tek satır
    component ExtraLineBar: ColumnLayout {
        id: extraBar

        property string labelText: ""
        property int usedPct: -1
        property string resetText: ""
        property color fillColor: barTheme.amber
        required property Theme barTheme

        readonly property bool hasVal: extraBar.usedPct >= 0
        readonly property int clamped: extraBar.hasVal ? Math.max(0, Math.min(100, extraBar.usedPct)) : 0

        Layout.fillWidth: true
        spacing: 5

        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Text {
                text: extraBar.labelText
                textFormat: Text.PlainText
                font.family: extraBar.barTheme.fontFamily
                font.pixelSize: 11
                color: extraBar.barTheme.subtext
            }

            MonoPct {
                pct: extraBar.usedPct
                numberSize: 11
                weight: Font.DemiBold
                numberColor: extraBar.barTheme.text
                pctTheme: extraBar.barTheme
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                text: extraBar.hasVal ? extraBar.resetText : ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                maximumLineCount: 1
                font.family: extraBar.barTheme.monoFamily
                font.pixelSize: 10
                color: extraBar.barTheme.mutedText
            }
        }

        Rectangle {
            id: thinTrack
            Layout.fillWidth: true
            Layout.preferredHeight: 3
            radius: 1.5
            color: extraBar.barTheme.track

            Rectangle {
                visible: extraBar.hasVal && extraBar.clamped > 0
                width: Math.max(0, Math.min(thinTrack.width, Math.round(thinTrack.width * (extraBar.clamped / 100.0))))
                height: parent.height
                radius: parent.radius
                color: extraBar.fillColor

                Behavior on width {
                    NumberAnimation {
                        duration: Kirigami.Units.longDuration
                        easing.type: Easing.OutCubic
                    }
                }

                Behavior on color {
                    ColorAnimation {
                        duration: Kirigami.Units.shortDuration
                    }
                }
            }
        }
    }

    // Kart başlıkları için ortak yenileme düğmesi (her sağlayıcı kartında)
    component RefreshHeaderButton: Item {
        id: btnRoot

        property string accessibleLabel: i18n("Refresh quotas")

        Layout.preferredWidth: 24
        Layout.preferredHeight: 24
        activeFocusOnTab: !root.quotasLoading
        Accessible.role: Accessible.Button
        Accessible.name: btnRoot.accessibleLabel
        opacity: root.quotasLoading ? 0.8 : (btnHover.hovered || btnRoot.activeFocus ? 1.0 : 0.7)

        Behavior on opacity {
            NumberAnimation { duration: Kirigami.Units.shortDuration }
        }

        Keys.onPressed: (event) => {
            if (!root.quotasLoading && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)) {
                root.triggerRefreshQuotas();
                event.accepted = true;
            }
        }

        Glyph {
            id: btnGlyph
            anchors.centerIn: parent
            name: "view-refresh-symbolic"
            size: 14
            color: (root.quotasLoading || btnHover.hovered || btnRoot.activeFocus)
                   ? root.lookTheme.amber
                   : root.lookTheme.subtext

            NumberAnimation on rotation {
                from: 0
                to: 360
                duration: 800
                loops: Animation.Infinite
                running: root.visible && root.quotasLoading
                onRunningChanged: {
                    if (!running) {
                        btnGlyph.rotation = 0;
                    }
                }
            }
        }

        HoverHandler {
            id: btnHover
        }

        MouseArea {
            anchors.fill: parent
            enabled: !root.quotasLoading
            cursorShape: root.quotasLoading ? Qt.ArrowCursor : Qt.PointingHandCursor
            onClicked: (mouse) => {
                mouse.accepted = true;
                btnRoot.forceActiveFocus();
                root.triggerRefreshQuotas();
            }
        }
    }

    // Sağlayıcı kartı: başlık + iç içe halka (dış 5sa, iç 7g) + iki pencere satırı + isteğe bağlı ek kova
    component ProviderCard: TonalCard {
        id: card

        property string title: ""
        property color dotColor: root.lookTheme.amber
        property var quota: ({})
        property string outerKey: "fiveHour"
        property string innerKey: "sevenDay"
        property string extraLabel: ""
        property string extraKey: ""
        property bool extraIs5h: false
        property color extraColor: root.lookTheme.amber

        readonly property bool avail: Boolean(card.quota && card.quota.available)
        // Yedek/önbellek verisi (uç erişilemedi, ≤30 dk eski): kart soluk çizilir.
        readonly property bool stale: card.avail && card.quota.source === "cache"
        readonly property var outerBucket: card.avail ? card.quota[card.outerKey] : null
        readonly property var innerBucket: card.avail ? card.quota[card.innerKey] : null
        readonly property var extraBucket: (card.avail && card.extraKey !== "") ? card.quota[card.extraKey] : null
        readonly property int outerUsed: root.bucketUsed(card.outerBucket)
        readonly property string cacheNote: root.backend ? root.backend.quotaNote(card.quota) : ""
        readonly property int innerUsed: root.bucketUsed(card.innerBucket)

        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredWidth: 1
        theme: root.lookTheme
        Accessible.role: Accessible.Grouping
        Accessible.name: card.cacheNote !== "" ? i18n("%1 quota (%2)", card.title, card.cacheNote) : i18n("%1 quota", card.title)

        HoverHandler {
            id: cardHover
        }

        QQC2.ToolTip.visible: card.cacheNote !== "" && cardHover.hovered
        QQC2.ToolTip.text: card.cacheNote
        QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12
            opacity: card.stale ? 0.55 : 1.0

            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 24
                spacing: 7

                Rectangle {
                    Layout.preferredWidth: 6
                    Layout.preferredHeight: 6
                    radius: 3
                    color: card.dotColor
                }

                Text {
                    Layout.fillWidth: true
                    text: card.title
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    font.family: root.lookTheme.fontFamily
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    color: root.lookTheme.text
                }

                RefreshHeaderButton {
                    accessibleLabel: i18n("Refresh %1 quota", card.title)
                }
            }

            // Kullanılamama nedeni (Oturum süresi doldu vb.) başlığın altında küçük metin
            Text {
                Layout.fillWidth: true
                Layout.topMargin: -8
                visible: !card.avail && card.cacheNote !== ""
                text: card.cacheNote
                textFormat: Text.PlainText
                elide: Text.ElideRight
                font.family: root.lookTheme.fontFamily
                font.pixelSize: 10
                color: root.lookTheme.subtext
            }

            RingGauge {
                Layout.alignment: Qt.AlignHCenter
                size: 84
                thickness: 5.5
                value: card.outerUsed >= 0 ? (card.outerUsed / 100.0) : -1
                color: root.lookTheme.quotaColor(card.outerUsed)
                trackColor: root.lookTheme.track

                RingGauge {
                    anchors.centerIn: parent
                    size: 68
                    thickness: 3
                    value: card.innerUsed >= 0 ? (card.innerUsed / 100.0) : -1
                    color: root.lookTheme.quotaColor(card.innerUsed)
                    trackColor: root.lookTheme.track
                }

                MonoPct {
                    anchors.centerIn: parent
                    pct: card.outerUsed
                    numberSize: 20
                    weight: Font.Bold
                    numberColor: root.lookTheme.text
                    pctTheme: root.lookTheme
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6

                WindowLine {
                    tag: i18nc("5-hour quota window", "5h")
                    usedPct: card.outerUsed
                    resetText: root._shortReset5h(card.outerBucket)
                    rowTheme: root.lookTheme
                }

                WindowLine {
                    tag: i18nc("7-day quota window", "7d")
                    usedPct: card.innerUsed
                    resetText: root._shortReset7d(card.innerBucket)
                    rowTheme: root.lookTheme
                }
            }

            Item {
                Layout.fillHeight: true
            }

            ExtraLineBar {
                visible: card.extraLabel !== ""
                labelText: card.extraLabel
                usedPct: root.bucketUsed(card.extraBucket)
                resetText: card.extraIs5h ? root._shortReset5h(card.extraBucket) : root._shortReset7d(card.extraBucket)
                fillColor: card.extraColor
                barTheme: root.lookTheme
            }
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 10

        ProviderCard {
            visible: root.claudeShown
            title: "Claude"
            dotColor: root.lookTheme.orange
            quota: root.backend ? root.backend.claudeQuota : ({})
            extraLabel: "Fable"
            extraKey: "fableWeekly"
            extraColor: root.lookTheme.purple
        }

        // AGY: dış halka Gemini 5sa havuzu, iç halka haftalık; ek kova AGY içindeki Claude havuzu
        ProviderCard {
            visible: root.agyShown
            title: "AGY"
            dotColor: root.lookTheme.aqua
            quota: root.backend ? root.backend.agyQuota : ({})
            outerKey: "geminiPool"
            innerKey: "weekly"
            extraLabel: "Claude"
            extraKey: "claudePool"
            extraIs5h: true
            extraColor: root.lookTheme.orange
        }

        ProviderCard {
            visible: root.codexShown
            title: "Codex"
            dotColor: root.lookTheme.blue
            quota: root.backend ? root.backend.codexQuota : ({})
        }
    }
}
