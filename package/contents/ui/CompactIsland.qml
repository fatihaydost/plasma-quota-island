pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami
import QtQuick.Layouts

// KDE Plasma 6 üst paneli için v3.2 yarı saydam cam Quota Island kapsülü
// (Tam ortada üstte saat + altta gg.aa.yyyy tarih; solda logosuz kompakt medya, sağda 13px halkalar ve 5sa·7g kota rakamları).
Item {
    id: root

    property var backend: null
    property Theme theme: null
    property bool popupExpanded: false

    property int maxTrackWidth: 160
    property int volumeStep: 5
    property bool showVolumeBadge: true
    property bool showQuotaBadges: true
    property string quotaWindowMode: "both"

    Theme {
        id: fallbackTheme
    }

    readonly property Theme lookTheme: root.theme !== null ? root.theme : fallbackTheme

    // Sneak Peek HUD durumu (2500ms çapraz solan bildirim katmanı; kapsül genişliğini değiştirmez)
    property bool sneakPeekActive: false
    property string sneakPeekText: ""
    property color sneakPeekAccent: lookTheme.amber
    property string sneakPeekIcon: ""
    property string sneakPeekKind: ""

    signal clicked()
    signal requestExpand()

    // Panel boyutlandırma kuralları (zorunlu)
    Layout.minimumWidth: implicitWidth
    Layout.preferredWidth: implicitWidth
    Layout.fillHeight: true

    readonly property real panelThickness: height > 0 ? height : 38
    readonly property int pillHeight: Math.max(26, Math.min(34, Math.round(panelThickness - 4)))
    readonly property int hPad: 15
    readonly property int itemGap: 16
    readonly property int fontPx: Math.max(11, Math.min(13, Math.round(pillHeight * 0.38)))
    readonly property int smallFontPx: Math.max(9, fontPx - 2)

    // Canlı saat (üstte) ve sayısal tarih (altta, gün adı olmadan gg.aa.yyyy)
    property date currentClockTime: new Date()

    readonly property string clockDateLabel: currentClockTime.toLocaleDateString(Qt.locale(), Locale.ShortFormat)
    readonly property string clockTimeLabel: Qt.formatTime(currentClockTime, "HH:mm")

    Timer {
        id: clockTimer
        interval: 15000
        repeat: true
        running: root.visible
        triggeredOnStart: true
        onTriggered: {
            root.currentClockTime = new Date();
        }
    }

    // Medya durumu
    readonly property bool mediaAvailable: Boolean(backend && backend.mediaAvailable)
    readonly property string playbackStatus: (backend && backend.playbackStatus) ? String(backend.playbackStatus) : "Stopped"
    readonly property bool isPlaying: mediaAvailable && playbackStatus === "Playing"
    readonly property bool isPaused: mediaAvailable && playbackStatus === "Paused"
    readonly property bool showMediaMode: mediaAvailable && (isPlaying || isPaused)

    readonly property real lengthSec: (backend && backend.lengthSec !== undefined) ? Number(backend.lengthSec) : 0
    readonly property real positionSec: (backend && backend.positionSec !== undefined) ? Number(backend.positionSec) : 0
    readonly property real mediaProgress: (lengthSec > 0 && positionSec >= 0)
        ? Math.max(0.0, Math.min(1.0, positionSec / lengthSec))
        : -1.0

    readonly property string trackTitle: (backend && backend.trackTitle) ? String(backend.trackTitle) : ""
    readonly property string trackArtist: (backend && backend.trackArtist) ? String(backend.trackArtist) : ""
    readonly property var micApps: (backend && backend.micApps) ? backend.micApps : []
    readonly property bool micInUse: micApps.length > 0
    readonly property string playerIdentity: (backend && backend.playerIdentity) ? String(backend.playerIdentity) : i18n("Media")
    readonly property string displayTrack: {
        if (trackTitle !== "" && trackArtist !== "") {
            return trackTitle + " — " + trackArtist;
        }
        if (trackTitle !== "") {
            return trackTitle;
        }
        return playerIdentity;
    }
    readonly property string trackSignature: (showMediaMode && trackTitle !== "")
        ? (trackTitle + "\n" + trackArtist)
        : ""

    readonly property string safeArtUrl: {
        const raw = (backend && backend.artUrl) ? String(backend.artUrl) : "";
        if (raw.startsWith("file://") || raw.startsWith("https://")) {
            return raw;
        }
        return "";
    }

    readonly property bool canPrev: !backend || backend.canGoPrevious === undefined || Boolean(backend.canGoPrevious)
    readonly property bool canNext: !backend || backend.canGoNext === undefined || Boolean(backend.canGoNext)
    readonly property bool canTogglePlay: !backend || Boolean(backend.canPlay || backend.canPause || isPlaying || isPaused)

    // Ses durumu (sembolik ikon adı)
    readonly property int volume: (backend && backend.volume !== undefined) ? Number(backend.volume) : 0
    readonly property bool muted: Boolean(backend && backend.muted)
    readonly property string volumeIcon: {
        if (muted || volume <= 0) {
            return "audio-volume-muted-symbolic";
        }
        if (volume < 35) {
            return "audio-volume-low-symbolic";
        }
        if (volume < 75) {
            return "audio-volume-medium-symbolic";
        }
        return "audio-volume-high-symbolic";
    }

    // Herdr onay bekleyen (blocked) ajan sayısı; Herdr yok/kapalıysa 0 (Sneak Peek tetiklenmez)
    readonly property int herdrBlockedCount: (backend && backend.herdrShown)
        ? Math.max(0, Math.round(Number(backend.herdrBlockedCount)))
        : 0

    readonly property bool livePayloadSeen: Boolean(
        backend && (
            backend.liveUpdatedAt
            || backend.liveLoaded
            || (backend.liveData && typeof backend.liveData === "object" && Object.keys(backend.liveData).length > 0)
            || (backend.liveStatus && typeof backend.liveStatus === "object" && Object.keys(backend.liveStatus).length > 0)
        )
    )

    // Kota durumu (Claude, AGY, Codex); halka yalnız açık ve kimliği bulunan sağlayıcı için çizilir
    readonly property bool claudeAvailable: Boolean(backend && backend.claudeQuota && backend.claudeQuota.available)
    readonly property bool agyAvailable: Boolean(backend && backend.agyQuota && backend.agyQuota.available)

    readonly property int claude5h: (backend && backend.claude5hUsed !== undefined) ? Number(backend.claude5hUsed) : -1
    readonly property int claude7d: (backend && backend.claude7dUsed !== undefined) ? Number(backend.claude7dUsed) : -1
    readonly property int agyGem5h: (backend && backend.agyGemini5hUsed !== undefined) ? Number(backend.agyGemini5hUsed) : -1
    readonly property int agyCld5h: (backend && backend.agyClaude5hUsed !== undefined) ? Number(backend.agyClaude5hUsed) : -1
    readonly property int agy5h: Math.max(agyGem5h, agyCld5h)
    readonly property int agy7d: (backend && backend.agy7dUsed !== undefined) ? Number(backend.agy7dUsed) : -1
    readonly property bool codexAvailable: Boolean(backend && backend.codexQuota && backend.codexQuota.available)
    readonly property int codex5h: (backend && backend.codex5hUsed !== undefined) ? Number(backend.codex5hUsed) : -1
    readonly property int codex7d: (backend && backend.codex7dUsed !== undefined) ? Number(backend.codex7dUsed) : -1

    readonly property int claudeWorstUsed: claudeAvailable ? Math.max(claude5h, claude7d) : -1
    readonly property int agyWorstUsed: agyAvailable ? Math.max(agy5h, agy7d) : -1
    readonly property int codexWorstUsed: codexAvailable ? Math.max(codex5h, codex7d) : -1

    readonly property color claudeDotColor: lookTheme.quotaColor(claudeWorstUsed)
    readonly property color agyDotColor: lookTheme.quotaColor(agyWorstUsed)
    readonly property color codexDotColor: lookTheme.quotaColor(codexWorstUsed)

    function formatQuotaPair(a: int, b: int): string {
        if (a < 0 && b < 0) {
            return "--";
        }
        const left = a >= 0 ? String(a) : "--";
        const right = b >= 0 ? String(b) : "--";
        return left + "·" + right + "%";
    }

    // Ayardaki "Boştayken kota rozeti" (quotaWindowMode): both = "5·7%", 5h / 7d = tek değer.
    function quotaText(avail: bool, h5: int, d7: int): string {
        if (!avail) {
            return root.formatQuotaPair(-1, -1);
        }
        if (root.quotaWindowMode === "5h") {
            return h5 >= 0 ? (String(h5) + "%") : "--";
        }
        if (root.quotaWindowMode === "7d") {
            return d7 >= 0 ? (String(d7) + "%") : "--";
        }
        return root.formatQuotaPair(h5, d7);
    }

    readonly property string claudePairText: quotaText(claudeAvailable, claude5h, claude7d)

    // AGY'de haftalık özet yoksa "both" kipinde iki 5 saatlik havuz yan yana gösterilir.
    readonly property string agyPairText: (agyAvailable && agy7d < 0 && root.quotaWindowMode !== "5h" && root.quotaWindowMode !== "7d")
        ? formatQuotaPair(agyGem5h, agyCld5h)
        : quotaText(agyAvailable, agy5h, agy7d)

    readonly property string codexPairText: quotaText(codexAvailable, codex5h, codex7d)

    // Tema renk ve font yardımcıları
    readonly property color obsidianColor: lookTheme.obsidian
    readonly property color pillBgColor: lookTheme.pillBg
    readonly property color surfaceColor: lookTheme.surface
    readonly property color surfaceAltColor: lookTheme.surfaceAlt
    readonly property color borderColor: lookTheme.border
    readonly property color textColor: lookTheme.text
    readonly property color subtextColor: lookTheme.subtext
    readonly property color mutedTextColor: lookTheme.mutedText
    readonly property color accentColor: lookTheme.accent
    readonly property color accentBrightColor: lookTheme.accentBright
    readonly property color amberColor: lookTheme.amber
    readonly property color amberDimColor: lookTheme.amberDim
    readonly property color oliveColor: lookTheme.olive
    readonly property color aquaColor: lookTheme.aqua
    readonly property color orangeColor: lookTheme.orange
    readonly property color coralColor: lookTheme.coral
    readonly property color positiveColor: lookTheme.positive
    readonly property color warningColor: lookTheme.warning
    readonly property color negativeColor: lookTheme.negative
    readonly property string fontFamily: lookTheme.fontFamily
    readonly property string monoFamily: lookTheme.monoFamily

    readonly property bool dragActive: panelDropArea.containsDrag

    // Sneak Peek ilk yükleme koruması
    property bool _startupSettled: false
    property bool _seenFirstLiveLoad: false
    property int _prevVolume: 0
    property bool _prevMuted: false
    property string _prevTrackSignature: ""
    property int _prevBlockedCount: 0

    function _syncBaselines(): void {
        root._prevVolume = root.volume;
        root._prevMuted = root.muted;
        root._prevTrackSignature = root.trackSignature;
        root._prevBlockedCount = root.herdrBlockedCount;
    }

    function showSneakPeek(kind: string, iconStr: string, message: string, accentCol: color): void {
        root.sneakPeekKind = kind;
        root.sneakPeekIcon = iconStr;
        root.sneakPeekText = message;
        root.sneakPeekAccent = accentCol;
        root.sneakPeekActive = true;
        sneakPeekTimer.restart();
    }

    Timer {
        id: startupSettleTimer
        interval: 1500
        running: true
        repeat: false
        onTriggered: {
            root._syncBaselines();
            root._startupSettled = true;
        }
    }

    Timer {
        id: sneakPeekTimer
        interval: 2500
        repeat: false
        onTriggered: {
            root.sneakPeekActive = false;
        }
    }

    onLivePayloadSeenChanged: {
        if (root.livePayloadSeen && !root._seenFirstLiveLoad) {
            root._seenFirstLiveLoad = true;
            root._prevBlockedCount = root.herdrBlockedCount;
        }
    }

    onVolumeChanged: {
        if (!root._startupSettled) {
            root._prevVolume = root.volume;
            return;
        }
        if (root.volume !== root._prevVolume) {
            root._prevVolume = root.volume;
            const txt = root.muted ? i18n("Muted") : i18n("Volume");
            const col = root.muted ? root.coralColor : root.amberColor;
            root.showSneakPeek("volume", root.volumeIcon, txt, col);
        }
    }

    onMutedChanged: {
        if (!root._startupSettled) {
            root._prevMuted = root.muted;
            return;
        }
        if (root.muted !== root._prevMuted) {
            root._prevMuted = root.muted;
            root._prevVolume = root.volume;
            if (root.muted) {
                root.showSneakPeek("volume", "audio-volume-muted-symbolic", i18n("Muted"), root.coralColor);
            } else {
                root.showSneakPeek("volume", root.volumeIcon, i18n("Volume"), root.amberColor);
            }
        }
    }

    onTrackSignatureChanged: {
        if (!root._startupSettled) {
            root._prevTrackSignature = root.trackSignature;
            return;
        }
        if (root.trackSignature !== "" && root.trackSignature !== root._prevTrackSignature) {
            root.showSneakPeek("track", "emblem-music-symbolic", root.displayTrack, root.amberColor);
        }
        root._prevTrackSignature = root.trackSignature;
    }

    onHerdrBlockedCountChanged: {
        if (!root._startupSettled) {
            root._prevBlockedCount = root.herdrBlockedCount;
            return;
        }
        if (root.livePayloadSeen && !root._seenFirstLiveLoad) {
            root._seenFirstLiveLoad = true;
            root._prevBlockedCount = root.herdrBlockedCount;
            return;
        }
        if (root.herdrBlockedCount > root._prevBlockedCount) {
            const countText = i18np("1 agent awaiting approval", "%1 agents awaiting approval", root.herdrBlockedCount);
            root.showSneakPeek("blocked", "dialog-warning-symbolic", countText, root.coralColor);
        }
        root._prevBlockedCount = root.herdrBlockedCount;
    }

    Component.onCompleted: {
        root._syncBaselines();
    }

    // Hover, açık popup veya odakta başlık opaklıkla gizlenip aynı 72px yuvada 3 küçük Glyph düğmesi belirir
    readonly property bool showMiniControls: showMediaMode && !dragActive && !sneakPeekActive && (
        pillHover.hovered
        || popupExpanded
        || prevBtn.activeFocus
        || playBtn.activeFocus
        || nextBtn.activeFocus
    )

    // Tekerlek biriktiricisi (60 birim eşik ile hızlı ve hassas ses adımı)
    property int wheelDeltaAccum: 0

    function handleWheel(deltaY: int): void {
        if (!root.backend || deltaY === 0) {
            return;
        }
        root.wheelDeltaAccum += deltaY;
        const stepThreshold = 60;
        if (Math.abs(root.wheelDeltaAccum) >= stepThreshold) {
            if (!root._startupSettled) {
                root._syncBaselines();
                root._startupSettled = true;
            }
            const steps = Math.trunc(root.wheelDeltaAccum / stepThreshold);
            root.wheelDeltaAccum -= steps * stepThreshold;
            const stepPct = Math.max(1, root.volumeStep);
            root.backend.changeVolume(steps * stepPct);
        }
    }

    function toggleMuteFromUser(): void {
        if (!root.backend) {
            return;
        }
        if (!root._startupSettled) {
            root._syncBaselines();
            root._startupSettled = true;
        }
        root.backend.toggleMute();
    }

    // Çift tam sayıya sabitlenen kapsül genişliği (hover, sneak-peek ve sürüklemeden tamamen bağımsız)
    readonly property int targetWidth: {
        const rawW = mainRow.implicitWidth + root.hPad * 2 + 4;
        return Math.max(84, Math.ceil(rawW / 2) * 2);
    }

    implicitWidth: targetWidth
    implicitHeight: 38

    Behavior on implicitWidth {
        NumberAnimation {
            duration: Kirigami.Units.longDuration
            easing.type: Easing.OutCubic
        }
    }

    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: sneakPeekActive
        ? i18n("Quota Island notification: %1", sneakPeekText)
        : (showMediaMode
            ? i18n("Quota Island: %1 · %2", displayTrack, clockTimeLabel)
            : i18n("Quota Island: %1 %2", clockDateLabel, clockTimeLabel))

    Keys.onReturnPressed: root.clicked()
    Keys.onEnterPressed: root.clicked()
    Keys.onSpacePressed: root.clicked()
    Keys.onEscapePressed: {
        if (root.popupExpanded) {
            root.clicked();
        }
    }

    // Rakamları text, '·' ve '%' işaretlerini mutedText olarak çizen kompakt mono kota etiketi
    component QuotaPairLabel: Row {
        id: pairRoot

        required property string formatted
        required property color numColor
        required property color symColor
        required property string monoFont

        spacing: 0

        readonly property int dotIdx: formatted.indexOf("·")
        readonly property bool hasPair: dotIdx > 0 && formatted.endsWith("%")
        readonly property string firstPart: hasPair ? formatted.slice(0, dotIdx) : formatted
        readonly property string secondPart: hasPair ? formatted.slice(dotIdx + 1, formatted.length - 1) : ""

        Text {
            text: pairRoot.firstPart
            textFormat: Text.PlainText
            color: pairRoot.firstPart === "--" ? pairRoot.symColor : pairRoot.numColor
            font.family: pairRoot.monoFont
            font.pixelSize: 10
            font.weight: Font.Medium
        }

        Text {
            visible: pairRoot.hasPair
            text: "·"
            textFormat: Text.PlainText
            color: pairRoot.symColor
            font.family: pairRoot.monoFont
            font.pixelSize: 10
            font.weight: Font.Normal
        }

        Text {
            visible: pairRoot.hasPair
            text: pairRoot.secondPart
            textFormat: Text.PlainText
            color: pairRoot.secondPart === "--" ? pairRoot.symColor : pairRoot.numColor
            font.family: pairRoot.monoFont
            font.pixelSize: 10
            font.weight: Font.Medium
        }

        Text {
            visible: pairRoot.hasPair
            text: "%"
            textFormat: Text.PlainText
            color: pairRoot.symColor
            font.family: pairRoot.monoFont
            font.pixelSize: 10
            font.weight: Font.Normal
        }
    }

    // Panel kapsülü sürükle-bırak yakalayıcı (dosya, URL veya metin -> rafa ekle + popup aç)
    DropArea {
        id: panelDropArea
        anchors.fill: parent
        z: 10

        onEntered: (drag) => {
            if (drag.hasUrls || drag.hasText) {
                drag.acceptProposedAction();
            }
        }

        onDropped: (drop) => {
            const collected = [];
            if (drop.hasUrls && drop.urls && drop.urls.length > 0) {
                for (let i = 0; i < drop.urls.length; ++i) {
                    const u = String(drop.urls[i] || "").trim();
                    if (u !== "") {
                        collected.push(u);
                    }
                }
            } else if (drop.hasText && drop.text) {
                const txt = String(drop.text).trim();
                if (txt !== "") {
                    collected.push(txt);
                }
            }

            if (collected.length > 0) {
                if (root.backend && typeof root.backend.shelfAdd === "function") {
                    root.backend.shelfAdd(collected.length === 1 ? collected[0] : collected);
                }
                const feedback = i18np("Added to shelf", "%1 items added to shelf", collected.length);
                root.showSneakPeek("shelf", "window-pin-symbolic", feedback, root.oliveColor);
                root.requestExpand();
                drop.acceptProposedAction();
            }
        }
    }

    IslandSurface {
        id: pill

        width: Math.max(48, (root.width > 0 ? root.width : root.implicitWidth) - 4)
        height: root.pillHeight
        anchors.centerIn: parent
        radius: height / 2
        clip: true

        theme: root.lookTheme
        glass: true
        highlighted: pillHover.hovered || root.popupExpanded || root.activeFocus || root.dragActive
        rimColor: root.dragActive
            ? root.amberColor
            : (root.sneakPeekActive
                ? root.sneakPeekAccent
                : (highlighted ? root.lookTheme.rimStrong : root.lookTheme.rim))

        HoverHandler {
            id: pillHover
        }

        // Ana kapsül tıklama ve tekerlek alanı (sol tık: popup, orta tık: mute, tekerlek: ses)
        MouseArea {
            id: pillMouse
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            cursorShape: Qt.PointingHandCursor
            onClicked: (mouse) => {
                if (mouse.button === Qt.MiddleButton) {
                    root.toggleMuteFromUser();
                } else if (mouse.button === Qt.LeftButton) {
                    root.clicked();
                }
            }
            onWheel: (wheel) => {
                root.handleWheel(wheel.angleDelta.y);
                wheel.accepted = true;
            }
        }

        // ====================================================================
        // ANA İÇERİK SATIRI: Sol Logosuz Medya · Tam Ortada Saat/Tarih · Sağ 13px Halkalar + Kota
        // ====================================================================
        Row {
            id: mainRow
            anchors.centerIn: parent
            spacing: root.itemGap
            opacity: (root.sneakPeekActive || root.dragActive) ? 0.0 : 1.0
            z: 2

            Behavior on opacity {
                NumberAnimation { duration: Kirigami.Units.shortDuration }
            }

            // 1. SOL — LOGOSUZ KOMPAKT MEDYA (5 çubuklu 14px WaveBars + sağ kanatla dengeli sabit başlık yuvası)
            Row {
                id: mediaZone
                visible: root.showMediaMode
                spacing: 8
                anchors.verticalCenter: parent.verticalCenter

                WaveBars {
                    id: waveBars
                    active: root.isPlaying
                    theme: root.lookTheme
                    barCount: 5
                    barWidth: 2
                    barSpacing: 2
                    minBarHeight: 3
                    maxBarHeight: 14
                    height: 14
                    anchors.verticalCenter: parent.verticalCenter
                }

                // Sağ kanat (ringsZone) genişliğiyle dengelenen sabit yuva: saat/tarih tam ortada kalır, hover'da genişlik değişmez
                Item {
                    id: titleSlot
                    readonly property int balancedW: ringsZone.visible
                        ? Math.max(76, Math.round(ringsZone.implicitWidth - waveBars.width - mediaZone.spacing))
                        : 92
                    readonly property int maxSlotW: Math.min(136, Math.max(76, root.maxTrackWidth))
                    readonly property int slotWidth: Math.max(76, Math.min(maxSlotW, balancedW))
                    width: slotWidth
                    height: root.pillHeight
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        id: trackLabel
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        text: root.displayTrack
                        textFormat: Text.PlainText
                        color: root.lookTheme.text
                        font.family: root.fontFamily
                        font.pixelSize: 11
                        font.weight: Font.Medium
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        opacity: root.showMiniControls ? 0.0 : 0.86

                        Behavior on opacity {
                            NumberAnimation { duration: Kirigami.Units.shortDuration }
                        }
                    }

                    Row {
                        id: miniControlsRow
                        anchors.centerIn: parent
                        spacing: 3
                        opacity: root.showMiniControls ? 1.0 : 0.0
                        enabled: root.showMiniControls

                        Behavior on opacity {
                            NumberAnimation { duration: Kirigami.Units.shortDuration }
                        }

                        // Önceki parça
                        Item {
                            id: prevBtn
                            width: 17
                            height: 18
                            opacity: root.canPrev ? 1.0 : 0.35
                            activeFocusOnTab: root.showMiniControls && root.canPrev
                            Accessible.role: Accessible.Button
                            Accessible.name: i18n("Previous track")

                            Keys.onReturnPressed: {
                                if (root.backend && root.canPrev) {
                                    root.backend.previous();
                                }
                            }
                            Keys.onSpacePressed: {
                                if (root.backend && root.canPrev) {
                                    root.backend.previous();
                                }
                            }

                            HoverHandler {
                                id: prevHover
                            }

                            Glyph {
                                anchors.centerIn: parent
                                name: "media-skip-backward-symbolic"
                                size: 11
                                color: (prevHover.hovered || prevBtn.activeFocus) ? root.amberColor : root.subtextColor
                            }

                            MouseArea {
                                anchors.fill: parent
                                enabled: root.showMiniControls
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                cursorShape: root.canPrev ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: (mouse) => {
                                    if (mouse.button === Qt.MiddleButton) {
                                        root.toggleMuteFromUser();
                                    } else if (root.backend && root.canPrev) {
                                        root.backend.previous();
                                    }
                                }
                                onWheel: (wheel) => {
                                    root.handleWheel(wheel.angleDelta.y);
                                    wheel.accepted = true;
                                }
                            }
                        }

                        // Oynat / Duraklat
                        Item {
                            id: playBtn
                            width: 17
                            height: 18
                            opacity: root.canTogglePlay ? 1.0 : 0.35
                            activeFocusOnTab: root.showMiniControls && root.canTogglePlay
                            Accessible.role: Accessible.Button
                            Accessible.name: root.isPlaying ? i18n("Pause") : i18n("Play")

                            Keys.onReturnPressed: {
                                if (root.backend && root.canTogglePlay) {
                                    root.backend.playPause();
                                }
                            }
                            Keys.onSpacePressed: {
                                if (root.backend && root.canTogglePlay) {
                                    root.backend.playPause();
                                }
                            }

                            HoverHandler {
                                id: playHover
                            }

                            Glyph {
                                anchors.centerIn: parent
                                name: root.isPlaying ? "media-playback-pause-symbolic" : "media-playback-start-symbolic"
                                size: 11
                                color: (playHover.hovered || playBtn.activeFocus) ? root.amberColor : root.textColor
                            }

                            MouseArea {
                                anchors.fill: parent
                                enabled: root.showMiniControls
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                cursorShape: root.canTogglePlay ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: (mouse) => {
                                    if (mouse.button === Qt.MiddleButton) {
                                        root.toggleMuteFromUser();
                                    } else if (root.backend && root.canTogglePlay) {
                                        root.backend.playPause();
                                    }
                                }
                                onWheel: (wheel) => {
                                    root.handleWheel(wheel.angleDelta.y);
                                    wheel.accepted = true;
                                }
                            }
                        }

                        // Sonraki parça
                        Item {
                            id: nextBtn
                            width: 17
                            height: 18
                            opacity: root.canNext ? 1.0 : 0.35
                            activeFocusOnTab: root.showMiniControls && root.canNext
                            Accessible.role: Accessible.Button
                            Accessible.name: i18n("Next track")

                            Keys.onReturnPressed: {
                                if (root.backend && root.canNext) {
                                    root.backend.next();
                                }
                            }
                            Keys.onSpacePressed: {
                                if (root.backend && root.canNext) {
                                    root.backend.next();
                                }
                            }

                            HoverHandler {
                                id: nextHover
                            }

                            Glyph {
                                anchors.centerIn: parent
                                name: "media-skip-forward-symbolic"
                                size: 11
                                color: (nextHover.hovered || nextBtn.activeFocus) ? root.amberColor : root.subtextColor
                            }

                            MouseArea {
                                anchors.fill: parent
                                enabled: root.showMiniControls
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                cursorShape: root.canNext ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: (mouse) => {
                                    if (mouse.button === Qt.MiddleButton) {
                                        root.toggleMuteFromUser();
                                    } else if (root.backend && root.canNext) {
                                        root.backend.next();
                                    }
                                }
                                onWheel: (wheel) => {
                                    root.handleWheel(wheel.angleDelta.y);
                                    wheel.accepted = true;
                                }
                            }
                        }
                    }
                }
            }

            // 2. ORTA — TAM MERKEZDE ÜSTTE SAAT ('22:48'), ALTTA TARİH ('14.11.2026')
            Item {
                id: clockZone
                implicitWidth: Math.max(timePartText.implicitWidth, datePartText.implicitWidth)
                implicitHeight: root.pillHeight
                width: implicitWidth
                height: implicitHeight
                anchors.verticalCenter: parent.verticalCenter

                Text {
                    id: timePartText
                    text: root.clockTimeLabel
                    textFormat: Text.PlainText
                    color: root.lookTheme.text
                    font.family: root.monoFamily
                    font.pixelSize: 12
                    font.weight: Font.Bold
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: -6
                }

                Text {
                    id: datePartText
                    text: root.clockDateLabel
                    textFormat: Text.PlainText
                    color: root.lookTheme.subtext
                    font.family: root.monoFamily
                    font.pixelSize: 8
                    font.weight: Font.Medium
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: 6
                }
            }

            // 3. SAĞ — 13px HALKALAR + KOMPAKT İKİLİ KOTA RAKAMLARI (Ses yanında rakam yok)
            Row {
                id: ringsZone
                visible: root.showVolumeBadge || root.showQuotaBadges || root.herdrBlockedCount > 0 || root.micInUse
                spacing: 8
                anchors.verticalCenter: parent.verticalCenter

                // Mikrofon kullanımda: kota noktalarından ayrı biçim (halka değil, mikrofon glifi), ses halkasından önce.
                Glyph {
                    visible: root.micInUse
                    name: "microphone-sensitivity-high-symbolic"
                    size: 11
                    color: root.coralColor
                    anchors.verticalCenter: parent.verticalCenter
                    Accessible.role: Accessible.Indicator
                    Accessible.name: i18n("Microphone in use by %1", root.micApps.join(", "))
                }

                // Ses halkası (13px, merkezde 8px hacim glifi, yanında rakam yok)
                RingGauge {
                    visible: root.showVolumeBadge
                    size: 13
                    thickness: 2
                    value: Math.max(0.0, Math.min(1.0, root.volume / 100.0))
                    color: root.muted ? root.coralColor : root.amberColor
                    trackColor: root.muted
                        ? root.lookTheme.tint(root.coralColor, 0.30)
                        : root.lookTheme.track
                    anchors.verticalCenter: parent.verticalCenter

                    Glyph {
                        anchors.centerIn: parent
                        name: root.volumeIcon
                        size: 7
                        color: root.muted ? root.coralColor : root.subtextColor
                    }
                }

                // Claude halkası (13px, merkezde orange nokta) + '14·29%'
                Row {
                    visible: root.showQuotaBadges && Boolean(root.backend && root.backend.claudeShown)
                    opacity: (root.backend && root.backend.claudeQuota.source === "cache") ? 0.5 : 1.0
                    Accessible.role: Accessible.StaticText
                    Accessible.name: {
                        const base = i18n("%1 quota: %2", "Claude", root.claudePairText);
                        const note = root.backend ? root.backend.quotaNote(root.backend.claudeQuota) : "";
                        return note !== "" ? (base + " · " + note) : base;
                    }
                    spacing: 4
                    anchors.verticalCenter: parent.verticalCenter

                    RingGauge {
                        size: 13
                        thickness: 2
                        value: root.claudeWorstUsed >= 0 ? (root.claudeWorstUsed / 100.0) : -1.0
                        color: root.claudeDotColor
                        trackColor: root.lookTheme.track
                        dotSize: 4
                        dotColor: root.orangeColor
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    QuotaPairLabel {
                        formatted: root.claudePairText
                        numColor: root.textColor
                        symColor: root.mutedTextColor
                        monoFont: root.monoFamily
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // AGY halkası (13px, merkezde aqua nokta) + '17·5%' veya '17·0%'
                Row {
                    visible: root.showQuotaBadges && Boolean(root.backend && root.backend.agyShown)
                    opacity: (root.backend && root.backend.agyQuota.source === "cache") ? 0.5 : 1.0
                    Accessible.role: Accessible.StaticText
                    Accessible.name: {
                        const base = i18n("%1 quota: %2", "AGY", root.agyPairText);
                        const note = root.backend ? root.backend.quotaNote(root.backend.agyQuota) : "";
                        return note !== "" ? (base + " · " + note) : base;
                    }
                    spacing: 4
                    anchors.verticalCenter: parent.verticalCenter

                    RingGauge {
                        size: 13
                        thickness: 2
                        value: root.agyWorstUsed >= 0 ? (root.agyWorstUsed / 100.0) : -1.0
                        color: root.agyDotColor
                        trackColor: root.lookTheme.track
                        dotSize: 4
                        dotColor: root.aquaColor
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    QuotaPairLabel {
                        formatted: root.agyPairText
                        numColor: root.textColor
                        symColor: root.mutedTextColor
                        monoFont: root.monoFamily
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // Codex halkası (13px, merkezde blue nokta) + '12·40%'
                Row {
                    visible: root.showQuotaBadges && Boolean(root.backend && root.backend.codexShown)
                    opacity: (root.backend && root.backend.codexQuota.source === "cache") ? 0.5 : 1.0
                    Accessible.role: Accessible.StaticText
                    Accessible.name: {
                        const base = i18n("%1 quota: %2", "Codex", root.codexPairText);
                        const note = root.backend ? root.backend.quotaNote(root.backend.codexQuota) : "";
                        return note !== "" ? (base + " · " + note) : base;
                    }
                    spacing: 4
                    anchors.verticalCenter: parent.verticalCenter

                    RingGauge {
                        size: 13
                        thickness: 2
                        value: root.codexWorstUsed >= 0 ? (root.codexWorstUsed / 100.0) : -1.0
                        color: root.codexDotColor
                        trackColor: root.lookTheme.track
                        dotSize: 4
                        dotColor: root.lookTheme.blue
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    QuotaPairLabel {
                        formatted: root.codexPairText
                        numColor: root.textColor
                        symColor: root.mutedTextColor
                        monoFont: root.monoFamily
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // Engelli ajan uyarısı (zeminsiz 12px coral glif, sayı yok)
                Glyph {
                    visible: root.herdrBlockedCount > 0
                    name: "dialog-warning-symbolic"
                    size: 12
                    color: root.coralColor
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        // ====================================================================
        // SNEAK-PEEK HUD KATMANI (aynı genişlikte çapraz solma; ses yüzdesi yalnız burada görünür)
        // ====================================================================
        Item {
            id: sneakPeekLayer
            anchors.fill: parent
            anchors.leftMargin: root.hPad
            anchors.rightMargin: root.hPad
            opacity: (root.sneakPeekActive && !root.dragActive) ? 1.0 : 0.0
            z: 3

            Behavior on opacity {
                NumberAnimation { duration: Kirigami.Units.shortDuration }
            }

            Row {
                anchors.centerIn: parent
                spacing: 6

                Glyph {
                    visible: root.sneakPeekIcon !== ""
                    name: root.sneakPeekIcon
                    size: 13
                    color: root.sneakPeekAccent
                    anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                    text: root.sneakPeekText
                    textFormat: Text.PlainText
                    color: (root.sneakPeekKind === "volume" && root.muted) ? root.coralColor : root.textColor
                    font.family: (root.sneakPeekKind !== "track" && /\d/.test(root.sneakPeekText))
                        ? root.monoFamily
                        : root.fontFamily
                    font.pixelSize: root.fontPx
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    width: Math.min(
                        implicitWidth,
                        Math.max(32, sneakPeekLayer.width - (root.sneakPeekKind === "volume" ? 56 : 22))
                    )
                    anchors.verticalCenter: parent.verticalCenter
                }

                Row {
                    visible: root.sneakPeekKind === "volume"
                    spacing: 0
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        id: sneakVolNum
                        text: String(root.volume)
                        textFormat: Text.PlainText
                        color: root.muted ? root.coralColor : root.textColor
                        font.family: root.monoFamily
                        font.pixelSize: root.fontPx
                        font.weight: Font.DemiBold
                    }

                    Text {
                        text: "%"
                        textFormat: Text.PlainText
                        color: root.muted ? root.lookTheme.tint(root.coralColor, 0.75) : root.mutedTextColor
                        font.family: root.monoFamily
                        font.pixelSize: Math.max(8, root.fontPx - 2)
                        font.weight: Font.Medium
                        anchors.baseline: sneakVolNum.baseline
                    }
                }
            }
        }

        // ====================================================================
        // BIRAKMA İPUCU KATMANI (aynı genişlikte çapraz solma)
        // ====================================================================
        Item {
            id: dropLayer
            anchors.fill: parent
            opacity: root.dragActive ? 1.0 : 0.0
            z: 4

            Behavior on opacity {
                NumberAnimation { duration: Kirigami.Units.shortDuration }
            }

            Rectangle {
                anchors.fill: parent
                anchors.margins: 1
                radius: Math.max(0, pill.radius - 1)
                border.width: 0
                color: root.lookTheme.tint(root.amberColor, 0.10)
            }

            Row {
                anchors.centerIn: parent
                spacing: 6

                Glyph {
                    name: "folder-download-symbolic"
                    size: 13
                    color: root.amberColor
                    anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                    text: i18n("Drop on shelf")
                    textFormat: Text.PlainText
                    color: root.amberColor
                    font.family: root.fontFamily
                    font.pixelSize: root.fontPx
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    width: Math.min(implicitWidth, Math.max(36, dropLayer.width - 34))
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }
}
