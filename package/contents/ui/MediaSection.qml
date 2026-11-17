pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami
import QtQuick.Layouts
import QtQuick.Effects

// Plak görünümlü + ekolayzır seek bar'lı medya oynatıcısı (Medya & Ses sekmesi).
Item {
    id: root

    property var backend: null
    property Theme theme: null
    property bool compact: false

    Theme {
        id: fallbackTheme
    }

    readonly property Theme lookTheme: root.theme !== null ? root.theme : fallbackTheme

    readonly property bool mediaAvailable: Boolean(root.backend && root.backend.mediaAvailable)
    readonly property string activePlayerBus: (root.backend && root.backend.activePlayer) ? String(root.backend.activePlayer) : ""
    readonly property string playerIdentity: (root.backend && root.backend.playerIdentity) ? String(root.backend.playerIdentity) : ""
    readonly property string playbackStatus: (root.backend && root.backend.playbackStatus) ? String(root.backend.playbackStatus) : "Stopped"
    readonly property bool isPlaying: root.mediaAvailable && root.playbackStatus === "Playing"
    readonly property bool isPaused: root.mediaAvailable && root.playbackStatus === "Paused"
    readonly property string trackTitle: (root.backend && root.backend.trackTitle) ? String(root.backend.trackTitle) : ""
    readonly property string trackArtist: (root.backend && root.backend.trackArtist) ? String(root.backend.trackArtist) : ""
    readonly property string trackAlbum: (root.backend && root.backend.trackAlbum) ? String(root.backend.trackAlbum) : ""

    function sanitizeArtUrl(rawUrl: string): string {
        const trimmed = rawUrl.trim();
        if (trimmed.startsWith("file://") || trimmed.startsWith("https://")) {
            return trimmed;
        }
        return "";
    }

    readonly property string rawArtUrl: (root.backend && root.backend.artUrl) ? String(root.backend.artUrl) : ""
    readonly property string artUrl: root.sanitizeArtUrl(root.rawArtUrl)
    readonly property real lengthSec: (root.backend && Number(root.backend.lengthSec) > 0) ? Number(root.backend.lengthSec) : 0.0
    readonly property real rawPositionSec: (root.backend && Number(root.backend.positionSec) >= 0) ? Number(root.backend.positionSec) : 0.0
    readonly property bool canPlay: Boolean(root.backend && root.backend.canPlay)
    readonly property bool canPause: Boolean(root.backend && root.backend.canPause)
    readonly property bool canGoNext: Boolean(root.backend && root.backend.canGoNext)
    readonly property bool canGoPrevious: Boolean(root.backend && root.backend.canGoPrevious)
    readonly property bool canSeek: Boolean(root.backend && root.backend.canSeek) && root.lengthSec > 0.0
    readonly property var playersList: (root.backend && Array.isArray(root.backend.players)) ? root.backend.players : []

    property bool seeking: false
    property real seekPreviewSec: -1.0

    readonly property real effectivePositionSec: {
        if (root.seeking || root.seekPreviewSec >= 0.0) {
            return Math.max(0.0, Math.min(root.lengthSec, root.seekPreviewSec));
        }
        if (root.lengthSec > 0.0) {
            return Math.max(0.0, Math.min(root.lengthSec, root.rawPositionSec));
        }
        return Math.max(0.0, root.rawPositionSec);
    }

    readonly property real progressRatio: {
        if (root.lengthSec <= 0.0) {
            return 0.0;
        }
        return Math.max(0.0, Math.min(1.0, root.effectivePositionSec / root.lengthSec));
    }

    readonly property string secondaryLine: {
        const a = root.trackArtist.trim();
        const b = root.trackAlbum.trim();
        if (a !== "" && b !== "") {
            return a + " · " + b;
        }
        if (a !== "") {
            return a;
        }
        return b;
    }

    function formatTime(sec: real): string {
        if (!isFinite(sec) || sec < 0.0) {
            return "00:00";
        }
        const total = Math.floor(sec);
        const hours = Math.floor(total / 3600);
        const minutes = Math.floor((total % 3600) / 60);
        const seconds = total % 60;
        const mm = minutes < 10 ? ("0" + String(minutes)) : String(minutes);
        const ss = seconds < 10 ? ("0" + String(seconds)) : String(seconds);
        if (hours > 0) {
            return String(hours) + ":" + mm + ":" + ss;
        }
        return mm + ":" + ss;
    }

    function commitSeek(targetSec: real): void {
        if (!root.canSeek || !root.backend || typeof root.backend.seek !== "function") {
            return;
        }
        const clamped = Math.max(0.0, Math.min(root.lengthSec, targetSec));
        root.seekPreviewSec = clamped;
        seekHoldTimer.restart();
        root.backend.seek(clamped);
    }

    function triggerPlayPause(): void {
        if (root.backend && typeof root.backend.playPause === "function") {
            root.backend.playPause();
        }
    }

    function triggerPrevious(): void {
        if (root.backend && typeof root.backend.previous === "function") {
            root.backend.previous();
        }
    }

    function triggerNext(): void {
        if (root.backend && typeof root.backend.next === "function") {
            root.backend.next();
        }
    }

    function triggerSelectPlayer(busName: string): void {
        if (busName !== "" && root.backend && typeof root.backend.selectPlayer === "function") {
            root.backend.selectPlayer(busName);
        }
    }

    Timer {
        id: seekHoldTimer
        interval: 900
        repeat: false
        onTriggered: {
            if (!root.seeking) {
                root.seekPreviewSec = -1.0;
            }
        }
    }

    implicitWidth: 256
    implicitHeight: 388

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 10

        // 1. Üst başlık: durum noktası + NOW PLAYING + 33⅓ RPM
        RowLayout {
            Layout.fillWidth: true
            spacing: 7

            Rectangle {
                Layout.preferredWidth: 7
                Layout.preferredHeight: 7
                radius: 3.5
                color: root.isPlaying ? root.lookTheme.coral : root.lookTheme.mutedText
            }

            Text {
                text: root.isPlaying
                      ? i18n("NOW PLAYING")
                      : (root.mediaAvailable ? i18n("PAUSED") : i18n("STANDBY"))
                textFormat: Text.PlainText
                font.family: root.lookTheme.monoFamily
                font.pixelSize: 9
                font.weight: Font.Bold
                font.letterSpacing: 1.2
                color: root.isPlaying ? root.lookTheme.amber : root.lookTheme.mutedText
            }

            Item {
                Layout.fillWidth: true
            }

            Text {
                text: root.playerIdentity !== "" ? (root.playerIdentity.toUpperCase() + " · 33⅓ RPM") : "33⅓ RPM"
                textFormat: Text.PlainText
                font.family: root.lookTheme.monoFamily
                font.pixelSize: 9
                color: root.lookTheme.mutedText
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: root.lookTheme.divider
        }

        // Oynatıcı çipleri (birden fazla oynatıcı varsa)
        Flickable {
            Layout.fillWidth: true
            Layout.preferredHeight: 24
            visible: root.playersList.length > 1
            contentWidth: playerPillsRow.implicitWidth
            contentHeight: height
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Row {
                id: playerPillsRow
                height: parent.height
                spacing: 6

                Repeater {
                    model: root.playersList

                    delegate: Rectangle {
                        id: playerChip

                        required property var modelData
                        required property int index

                        readonly property string busName: playerChip.modelData && playerChip.modelData.busName
                                                          ? String(playerChip.modelData.busName) : ""
                        readonly property string chipLabel: playerChip.modelData && playerChip.modelData.identity
                                                            ? String(playerChip.modelData.identity)
                                                            : (playerChip.busName !== "" ? playerChip.busName : i18n("Player %1", playerChip.index + 1))
                        readonly property bool chipPlaying: Boolean(playerChip.modelData && playerChip.modelData.playbackStatus === "Playing")
                        readonly property bool isSelected: playerChip.busName !== "" && playerChip.busName === root.activePlayerBus

                        width: Math.min(140, chipRow.implicitWidth + 18)
                        height: 24
                        anchors.verticalCenter: parent.verticalCenter
                        radius: 12
                        color: playerChip.isSelected
                               ? root.lookTheme.surfaceAlt
                               : ((chipMouse.containsMouse || playerChip.activeFocus) ? root.lookTheme.surface : root.lookTheme.cardAlt)

                        Behavior on color {
                            ColorAnimation { duration: Kirigami.Units.shortDuration }
                        }

                        RowLayout {
                            id: chipRow
                            anchors.fill: parent
                            anchors.leftMargin: 9
                            anchors.rightMargin: 9
                            spacing: 5

                            Rectangle {
                                visible: playerChip.chipPlaying
                                Layout.preferredWidth: 4
                                Layout.preferredHeight: 4
                                radius: 2
                                color: root.lookTheme.olive
                            }

                            Text {
                                Layout.fillWidth: true
                                text: playerChip.chipLabel
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                maximumLineCount: 1
                                font.family: root.lookTheme.fontFamily
                                font.pixelSize: 11
                                font.weight: playerChip.isSelected ? Font.DemiBold : Font.Normal
                                color: playerChip.isSelected
                                       ? root.lookTheme.amber
                                       : (chipMouse.containsMouse ? root.lookTheme.text : root.lookTheme.subtext)
                            }
                        }

                        MouseArea {
                            id: chipMouse
                            Accessible.role: Accessible.Button
                            Accessible.name: i18n("Select player %1", playerChip.chipLabel)
                            Accessible.onPressAction: root.triggerSelectPlayer(playerChip.busName)
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.triggerSelectPlayer(playerChip.busName)
                        }
                    }
                }
            }
        }

        // 2. Plak (92x92) + Başlık & Sanatçı
        Item {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 92
            Layout.preferredHeight: 92

            Rectangle {
                anchors.fill: parent
                radius: 46
                color: "#111113"
                border.color: Qt.rgba(1, 1, 1, 0.14)
                border.width: 1

                Repeater {
                    model: [80, 70, 62]

                    delegate: Rectangle {
                        required property int modelData
                        anchors.centerIn: parent
                        width: modelData
                        height: modelData
                        radius: modelData / 2
                        color: "transparent"
                        border.color: Qt.rgba(1, 1, 1, 0.07)
                        border.width: 1
                    }
                }

                Rectangle {
                    anchors.centerIn: parent
                    width: 54
                    height: 54
                    radius: 27
                    color: root.isPlaying ? root.lookTheme.amber : root.lookTheme.cardAlt

                    Image {
                        id: albumArtSource
                        anchors.fill: parent
                        source: root.artUrl
                        asynchronous: true
                        cache: false
                        fillMode: Image.PreserveAspectCrop
                        visible: false
                    }

                    Item {
                        id: coverMask
                        anchors.fill: parent
                        layer.enabled: true
                        layer.smooth: true
                        visible: false

                        Rectangle {
                            anchors.fill: parent
                            radius: 27
                            color: "#ffffff"
                        }
                    }

                    MultiEffect {
                        anchors.fill: parent
                        source: albumArtSource
                        visible: root.mediaAvailable && root.artUrl !== "" && albumArtSource.status === Image.Ready
                        maskEnabled: true
                        maskSource: coverMask
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1.0
                    }

                    Glyph {
                        anchors.centerIn: parent
                        visible: !root.mediaAvailable || root.artUrl === "" || albumArtSource.status !== Image.Ready
                        name: "media-optical-audio-symbolic"
                        size: 22
                        color: root.isPlaying ? root.lookTheme.obsidian : root.lookTheme.mutedText
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: 6
                        height: 6
                        radius: 3
                        color: "#111113"
                        border.color: Qt.rgba(1, 1, 1, 0.22)
                        border.width: 1
                    }
                }
            }

            MouseArea {
                Accessible.role: Accessible.Button
                Accessible.name: root.isPlaying ? i18n("Pause") : i18n("Play")
                Accessible.onPressAction: root.triggerPlayPause()
                anchors.fill: parent
                enabled: root.mediaAvailable && (root.canPlay || root.canPause)
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.triggerPlayPause()
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: root.mediaAvailable
                      ? (root.trackTitle !== "" ? root.trackTitle : i18n("Unknown track"))
                      : i18n("Nothing playing")
                textFormat: Text.PlainText
                elide: Text.ElideRight
                maximumLineCount: 1
                font.family: root.lookTheme.fontFamily
                font.pixelSize: 13
                font.weight: Font.Bold
                color: root.mediaAvailable ? root.lookTheme.text : root.lookTheme.subtext
            }

            Text {
                Layout.fillWidth: true
                Layout.preferredHeight: 15
                horizontalAlignment: Text.AlignHCenter
                text: root.mediaAvailable ? root.secondaryLine : i18n("Waiting for media")
                textFormat: Text.PlainText
                elide: Text.ElideRight
                maximumLineCount: 1
                font.family: root.lookTheme.fontFamily
                font.pixelSize: 11
                color: root.lookTheme.subtext
            }
        }

        Item {
            Layout.fillHeight: true
        }

        // 3. Panacea 38 çubuklu Ekolayzır Seek Bar + Süreler
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4

            Item {
                id: seekWaveBox
                Layout.fillWidth: true
                Layout.preferredHeight: 32

                readonly property real frac: seekMouse.pressed
                    ? Math.max(0.0, Math.min(1.0, seekMouse.mouseX / Math.max(1.0, width)))
                    : root.progressRatio

                WaveBars {
                    anchors.fill: parent
                    theme: root.lookTheme
                    active: root.isPlaying
                    barCount: 38
                    barSpacing: 2.5
                    minBarHeight: 3
                    maxBarHeight: 28
                    stretchToWidth: true
                    color: root.lookTheme.subtext
                    edgeBarColor: root.lookTheme.mutedText
                    inactiveColor: root.lookTheme.mutedText
                    inactiveOpacity: 0.25
                    opacity: root.isPlaying ? 0.28 : 0.22
                }

                Item {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: Math.round(seekWaveBox.width * seekWaveBox.frac)
                    clip: true

                    WaveBars {
                        width: seekWaveBox.width
                        height: seekWaveBox.height
                        theme: root.lookTheme
                        active: root.isPlaying
                        barCount: 38
                        barSpacing: 2.5
                        minBarHeight: 3
                        maxBarHeight: 28
                        stretchToWidth: true
                        color: root.lookTheme.amber
                        edgeBarColor: root.lookTheme.amberDim
                        inactiveColor: root.lookTheme.amber
                        inactiveOpacity: 0.85
                    }
                }

                Rectangle {
                    visible: root.canSeek && (seekMouse.containsMouse || seekMouse.pressed)
                    width: seekMouse.pressed ? 3 : 2
                    height: parent.height + 2
                    radius: 1.5
                    y: -1
                    x: Math.max(0, Math.min(seekWaveBox.width - width, Math.round(seekWaveBox.width * seekWaveBox.frac - width / 2)))
                    color: root.lookTheme.text
                }

                MouseArea {
                    id: seekMouse
                    Accessible.role: Accessible.Slider
                    Accessible.name: i18n("Seek")
                    anchors.fill: parent
                    anchors.topMargin: -4
                    anchors.bottomMargin: -4
                    enabled: root.canSeek
                    hoverEnabled: true
                    cursorShape: root.canSeek ? Qt.PointingHandCursor : Qt.ArrowCursor

                    function secFromX(posX: real): real {
                        const ratio = Math.max(0.0, Math.min(1.0, posX / Math.max(1.0, seekWaveBox.width)));
                        return ratio * root.lengthSec;
                    }

                    onPressed: (mouse) => {
                        if (!root.canSeek) {
                            return;
                        }
                        root.seeking = true;
                        root.seekPreviewSec = secFromX(mouse.x);
                    }
                    onPositionChanged: (mouse) => {
                        if (pressed && root.seeking) {
                            root.seekPreviewSec = secFromX(mouse.x);
                        }
                    }
                    onReleased: (mouse) => {
                        if (!root.seeking) {
                            return;
                        }
                        const target = secFromX(mouse.x);
                        root.seeking = false;
                        root.commitSeek(target);
                    }
                    onCanceled: {
                        root.seeking = false;
                        root.seekPreviewSec = -1.0;
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true

                Text {
                    text: root.formatTime(root.effectivePositionSec)
                    textFormat: Text.PlainText
                    font.family: root.lookTheme.monoFamily
                    font.pixelSize: root.lookTheme.fontSmall
                    color: root.lookTheme.mutedText
                }

                Item {
                    Layout.fillWidth: true
                }

                Text {
                    text: root.lengthSec > 0.0 ? root.formatTime(root.lengthSec) : "--:--"
                    textFormat: Text.PlainText
                    font.family: root.lookTheme.monoFamily
                    font.pixelSize: root.lookTheme.fontSmall
                    color: root.lookTheme.mutedText
                }
            }
        }

        // 4. 3 Geniş Kapsül Medya Kontrol Düğmesi
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            spacing: 8

            Rectangle {
                id: shuffleBtn
                visible: root.mediaAvailable && Boolean(root.backend && root.backend.canShuffle)
                readonly property bool isOn: Boolean(root.backend && root.backend.shuffle)
                Layout.preferredWidth: 34
                Layout.preferredHeight: 34
                radius: 11
                color: shuffleMouse.containsMouse ? root.lookTheme.surfaceAlt : root.lookTheme.cardAlt

                Behavior on color {
                    ColorAnimation { duration: Kirigami.Units.shortDuration }
                }

                Glyph {
                    anchors.centerIn: parent
                    name: "media-playlist-shuffle-symbolic"
                    size: 14
                    color: shuffleBtn.isOn ? root.lookTheme.amber : root.lookTheme.mutedText
                }

                MouseArea {
                    id: shuffleMouse
                    Accessible.role: Accessible.Button
                    Accessible.checkable: true
                    Accessible.checked: shuffleBtn.isOn
                    Accessible.name: i18n("Shuffle")
                    Accessible.onPressAction: root.backend.toggleShuffle()
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.backend.toggleShuffle()
                }
            }

            Rectangle {
                id: prevBtn
                readonly property bool actionAllowed: root.mediaAvailable && root.canGoPrevious
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                Layout.preferredHeight: 34
                radius: 11
                color: (prevMouse.containsMouse && prevBtn.actionAllowed)
                       ? root.lookTheme.surfaceAlt
                       : root.lookTheme.cardAlt
                opacity: prevBtn.actionAllowed ? 1.0 : 0.35

                Behavior on color {
                    ColorAnimation { duration: Kirigami.Units.shortDuration }
                }

                Glyph {
                    anchors.centerIn: parent
                    name: "media-skip-backward-symbolic"
                    size: 15
                    color: root.lookTheme.text
                }

                MouseArea {
                    id: prevMouse
                    Accessible.role: Accessible.Button
                    Accessible.name: i18n("Previous track")
                    Accessible.onPressAction: root.triggerPrevious()
                    anchors.fill: parent
                    enabled: prevBtn.actionAllowed
                    hoverEnabled: true
                    cursorShape: prevBtn.actionAllowed ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.triggerPrevious()
                }
            }

            Rectangle {
                id: playPauseBtn
                readonly property bool actionAllowed: root.mediaAvailable && (root.canPlay || root.canPause)
                Layout.fillWidth: true
                Layout.preferredWidth: 1.4
                Layout.preferredHeight: 34
                radius: 11
                color: (playMouse.containsMouse && playPauseBtn.actionAllowed)
                       ? Qt.lighter(root.lookTheme.amber, 1.08)
                       : root.lookTheme.amber
                opacity: playPauseBtn.actionAllowed ? 1.0 : 0.35

                Behavior on color {
                    ColorAnimation { duration: Kirigami.Units.shortDuration }
                }

                Glyph {
                    anchors.centerIn: parent
                    name: root.isPlaying ? "media-playback-pause-symbolic" : "media-playback-start-symbolic"
                    size: 16
                    color: root.lookTheme.obsidian
                }

                MouseArea {
                    id: playMouse
                    Accessible.role: Accessible.Button
                    Accessible.name: root.isPlaying ? i18n("Pause") : i18n("Play")
                    Accessible.onPressAction: root.triggerPlayPause()
                    anchors.fill: parent
                    enabled: playPauseBtn.actionAllowed
                    hoverEnabled: true
                    cursorShape: playPauseBtn.actionAllowed ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.triggerPlayPause()
                }
            }

            Rectangle {
                id: nextBtn
                readonly property bool actionAllowed: root.mediaAvailable && root.canGoNext
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                Layout.preferredHeight: 34
                radius: 11
                color: (nextMouse.containsMouse && nextBtn.actionAllowed)
                       ? root.lookTheme.surfaceAlt
                       : root.lookTheme.cardAlt
                opacity: nextBtn.actionAllowed ? 1.0 : 0.35

                Behavior on color {
                    ColorAnimation { duration: Kirigami.Units.shortDuration }
                }

                Glyph {
                    anchors.centerIn: parent
                    name: "media-skip-forward-symbolic"
                    size: 15
                    color: root.lookTheme.text
                }

                MouseArea {
                    id: nextMouse
                    Accessible.role: Accessible.Button
                    Accessible.name: i18n("Next track")
                    Accessible.onPressAction: root.triggerNext()
                    anchors.fill: parent
                    enabled: nextBtn.actionAllowed
                    hoverEnabled: true
                    cursorShape: nextBtn.actionAllowed ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.triggerNext()
                }
            }

            Rectangle {
                id: loopBtn
                visible: root.mediaAvailable && Boolean(root.backend && root.backend.canLoop)
                readonly property bool isOn: Boolean(root.backend && root.backend.loopStatus !== "" && root.backend.loopStatus !== "None")
                Layout.preferredWidth: 34
                Layout.preferredHeight: 34
                radius: 11
                color: loopMouse.containsMouse ? root.lookTheme.surfaceAlt : root.lookTheme.cardAlt

                Behavior on color {
                    ColorAnimation { duration: Kirigami.Units.shortDuration }
                }

                Glyph {
                    anchors.centerIn: parent
                    name: (root.backend && root.backend.loopStatus === "Track") ? "media-playlist-repeat-song-symbolic" : "media-playlist-repeat-symbolic"
                    size: 14
                    color: loopBtn.isOn ? root.lookTheme.amber : root.lookTheme.mutedText
                }

                MouseArea {
                    id: loopMouse
                    Accessible.role: Accessible.Button
                    Accessible.checkable: true
                    Accessible.checked: loopBtn.isOn
                    Accessible.name: (root.backend && root.backend.loopStatus === "Track") ? i18n("Repeat track") : i18n("Repeat")
                    Accessible.onPressAction: root.backend.cycleLoop()
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.backend.cycleLoop()
                }
            }
        }
    }
}
