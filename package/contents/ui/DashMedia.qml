pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami
import QtQuick.Layouts
import QtQuick.Effects

// Plak görünümlü medya kartı:
// Sol: 74x74 plak (4 eşmerkezli oluk halkası + 44x44 dairesel kapak + 5x5 mil deliği, tıkla=oynat/duraklat)
// Orta: NOW PLAYING / 33⅓ RPM üst satırı + Başlık/Sanatçı + 44 çubuklu interaktif WaveBars ekolayzır seek bar
// Sağ: 3 yuvarlatılmış medya kontrol düğmesi (⏮, dolgulu ⏯, ⏭)
Item {
    id: root

    property var backend: null
    property Theme theme: null

    Theme {
        id: fallbackTheme
    }

    readonly property Theme lookTheme: root.theme !== null ? root.theme : fallbackTheme

    readonly property bool mediaAvailable: Boolean(root.backend && root.backend.mediaAvailable)
    readonly property string playbackStatus: (root.backend && root.backend.playbackStatus) ? String(root.backend.playbackStatus) : "Stopped"
    readonly property bool isPlaying: root.mediaAvailable && root.playbackStatus === "Playing"
    readonly property string trackTitle: (root.backend && root.backend.trackTitle) ? String(root.backend.trackTitle) : ""
    readonly property string trackArtist: (root.backend && root.backend.trackArtist) ? String(root.backend.trackArtist) : ""
    readonly property string playerIdentity: (root.backend && root.backend.playerIdentity) ? String(root.backend.playerIdentity) : ""

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

    readonly property real progressRatio: root.lengthSec > 0.0
        ? Math.max(0.0, Math.min(1.0, root.effectivePositionSec / root.lengthSec))
        : 0.0

    readonly property bool canPlay: Boolean(root.backend && root.backend.canPlay)
    readonly property bool canPause: Boolean(root.backend && root.backend.canPause)
    readonly property bool canGoNext: Boolean(root.backend && root.backend.canGoNext)
    readonly property bool canGoPrevious: Boolean(root.backend && root.backend.canGoPrevious)
    readonly property bool canSeek: Boolean(root.backend && root.backend.canSeek) && root.lengthSec > 0.0

    function formatTime(sec: real): string {
        if (!isFinite(sec) || sec < 0.0) {
            return "0:00";
        }
        const total = Math.floor(sec);
        const mins = Math.floor(total / 60);
        const secs = total % 60;
        return String(mins) + ":" + (secs < 10 ? ("0" + String(secs)) : String(secs));
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

    implicitWidth: 532
    implicitHeight: 108

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 14
        anchors.topMargin: 10
        anchors.bottomMargin: 10
        spacing: 14

        // 1. SOL: Plak (74x74, 4 oluk halkası + 44x44 kapak + 5x5 mil deliği)
        Item {
            id: vinylBox
            Layout.preferredWidth: 74
            Layout.preferredHeight: 74
            Layout.alignment: Qt.AlignVCenter

            Rectangle {
                id: vinylDisc
                anchors.fill: parent
                radius: 37
                color: "#111113"
                border.color: Qt.rgba(1, 1, 1, 0.14)
                border.width: 1

                Repeater {
                    model: [64, 56, 49]

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

                // Plak göbek etiketi (44x44)
                Rectangle {
                    anchors.centerIn: parent
                    width: 44
                    height: 44
                    radius: 22
                    color: root.isPlaying ? root.lookTheme.amber : root.lookTheme.cardAlt

                    Image {
                        id: coverSource
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
                            radius: 22
                            color: "#ffffff"
                        }
                    }

                    MultiEffect {
                        anchors.fill: parent
                        source: coverSource
                        visible: root.mediaAvailable && root.artUrl !== "" && coverSource.status === Image.Ready
                        maskEnabled: true
                        maskSource: coverMask
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1.0
                    }

                    Glyph {
                        anchors.centerIn: parent
                        visible: !root.mediaAvailable || root.artUrl === "" || coverSource.status !== Image.Ready
                        name: "media-optical-audio-symbolic"
                        size: 18
                        color: root.isPlaying ? root.lookTheme.obsidian : root.lookTheme.mutedText
                    }

                    // Plak merkez mil deliği (5x5)
                    Rectangle {
                        anchors.centerIn: parent
                        width: 5
                        height: 5
                        radius: 2.5
                        color: "#111113"
                        border.color: Qt.rgba(1, 1, 1, 0.22)
                        border.width: 1
                    }
                }
            }

            MouseArea {
                Accessible.role: Accessible.Button
                Accessible.name: root.isPlaying ? i18n("Pause") : i18n("Play")
                Accessible.onPressAction: root.backend && typeof root.backend.playPause === "function" && root.backend.playPause()
                anchors.fill: parent
                enabled: root.mediaAvailable && (root.canPlay || root.canPause)
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                    if (root.backend && typeof root.backend.playPause === "function") {
                        root.backend.playPause();
                    }
                }
            }
        }

        // 2. ORTA: NOW PLAYING başlığı + Parça/Sanatçı + 44 çubuklu interaktif WaveBars Seek Bar
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 3

            // Üst durum şeridi (Nothing OS MusicWidget tarzı)
            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Rectangle {
                    Layout.preferredWidth: 6
                    Layout.preferredHeight: 6
                    radius: 3
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
                    font.letterSpacing: 1.1
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

            // Parça adı ve sanatçı (tek satırda temiz hiyerarşi)
            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    Layout.fillWidth: true
                    text: root.mediaAvailable
                          ? (root.trackTitle !== "" ? root.trackTitle : i18n("Unknown track"))
                          : i18n("No media playing")
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    font.family: root.lookTheme.fontFamily
                    font.pixelSize: 13
                    font.weight: Font.Bold
                    color: root.mediaAvailable ? root.lookTheme.text : root.lookTheme.subtext
                }

                Text {
                    visible: root.mediaAvailable && root.trackArtist !== ""
                    Layout.maximumWidth: 140
                    text: root.trackArtist
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    font.family: root.lookTheme.fontFamily
                    font.pixelSize: 11
                    color: root.lookTheme.subtext
                }
            }

            // 44 çubuklu Ekolayzır Seek Bar + Süre etiketleri
            Item {
                id: waveSeek
                Layout.fillWidth: true
                Layout.preferredHeight: 26

                readonly property real frac: seekArea.pressed
                    ? Math.max(0.0, Math.min(1.0, seekArea.mouseX / Math.max(1.0, width)))
                    : root.progressRatio

                // Oynatılmamış sönük ekolayzır çubukları (tam genişlik)
                WaveBars {
                    anchors.fill: parent
                    theme: root.lookTheme
                    active: root.isPlaying
                    barCount: 44
                    barSpacing: 2.5
                    minBarHeight: 3
                    maxBarHeight: 24
                    stretchToWidth: true
                    color: root.lookTheme.subtext
                    edgeBarColor: root.lookTheme.mutedText
                    inactiveColor: root.lookTheme.mutedText
                    inactiveOpacity: 0.26
                    opacity: root.isPlaying ? 0.28 : 0.22
                }

                // Oynatılmış parlak kehribar/vurgu ekolayzır çubukları (frac kadar kırpılmış)
                Item {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: Math.round(waveSeek.width * waveSeek.frac)
                    clip: true

                    WaveBars {
                        width: waveSeek.width
                        height: waveSeek.height
                        theme: root.lookTheme
                        active: root.isPlaying
                        barCount: 44
                        barSpacing: 2.5
                        minBarHeight: 3
                        maxBarHeight: 24
                        stretchToWidth: true
                        color: root.lookTheme.amber
                        edgeBarColor: root.lookTheme.amberDim
                        inactiveColor: root.lookTheme.amber
                        inactiveOpacity: 0.85
                    }
                }

                // Hover veya sürüklemede dikey scrub çizgisi
                Rectangle {
                    visible: root.canSeek && (seekArea.containsMouse || seekArea.pressed)
                    width: seekArea.pressed ? 3 : 2
                    height: parent.height + 2
                    radius: 1.5
                    y: -1
                    x: Math.max(0, Math.min(waveSeek.width - width, Math.round(waveSeek.width * waveSeek.frac - width / 2)))
                    color: root.lookTheme.text
                }

                MouseArea {
                    id: seekArea
                    Accessible.role: Accessible.Slider
                    Accessible.name: i18n("Seek")
                    anchors.fill: parent
                    anchors.topMargin: -4
                    anchors.bottomMargin: -4
                    enabled: root.canSeek
                    hoverEnabled: true
                    cursorShape: root.canSeek ? Qt.PointingHandCursor : Qt.ArrowCursor

                    function targetSecFromX(px: real): real {
                        const r = Math.max(0.0, Math.min(1.0, px / Math.max(1.0, waveSeek.width)));
                        return r * root.lengthSec;
                    }

                    onPressed: (mouse) => {
                        if (!root.canSeek) {
                            return;
                        }
                        root.seeking = true;
                        root.seekPreviewSec = targetSecFromX(mouse.x);
                    }
                    onPositionChanged: (mouse) => {
                        if (pressed && root.seeking) {
                            root.seekPreviewSec = targetSecFromX(mouse.x);
                        }
                    }
                    onReleased: (mouse) => {
                        if (!root.seeking) {
                            return;
                        }
                        const target = targetSecFromX(mouse.x);
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
                spacing: 4

                Text {
                    text: root.formatTime(root.effectivePositionSec)
                    textFormat: Text.PlainText
                    font.family: root.lookTheme.monoFamily
                    font.pixelSize: 9
                    color: root.lookTheme.mutedText
                }

                Item {
                    Layout.fillWidth: true
                }

                Text {
                    text: root.lengthSec > 0 ? root.formatTime(root.lengthSec) : "--:--"
                    textFormat: Text.PlainText
                    font.family: root.lookTheme.monoFamily
                    font.pixelSize: 9
                    color: root.lookTheme.mutedText
                }
            }
        }

        // 3. SAĞ: 3 Yuvarlatılmış Medya Düğmesi (⏮, dolgulu ⏯, ⏭)
        RowLayout {
            Layout.alignment: Qt.AlignVCenter
            spacing: 6

            Rectangle {
                id: prevBtn
                readonly property bool actionAllowed: root.mediaAvailable && root.canGoPrevious
                Layout.preferredWidth: 32
                Layout.preferredHeight: 32
                radius: 10
                color: prevMouse.containsMouse && actionAllowed ? root.lookTheme.surfaceAlt : root.lookTheme.cardAlt
                opacity: actionAllowed ? 1.0 : 0.35

                Behavior on color {
                    ColorAnimation { duration: Kirigami.Units.shortDuration }
                }

                Glyph {
                    anchors.centerIn: parent
                    name: "media-skip-backward-symbolic"
                    size: 14
                    color: root.lookTheme.text
                }

                MouseArea {
                    id: prevMouse
                    Accessible.role: Accessible.Button
                    Accessible.name: i18n("Previous track")
                    Accessible.onPressAction: root.backend && typeof root.backend.previous === "function" && root.backend.previous()
                    anchors.fill: parent
                    enabled: prevBtn.actionAllowed
                    hoverEnabled: true
                    cursorShape: prevBtn.actionAllowed ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        if (root.backend && typeof root.backend.previous === "function") {
                            root.backend.previous();
                        }
                    }
                }
            }

            Rectangle {
                id: playBtn
                readonly property bool actionAllowed: root.mediaAvailable && (root.canPlay || root.canPause)
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                radius: 12
                color: playMouse.containsMouse && actionAllowed
                       ? Qt.lighter(root.lookTheme.amber, 1.08)
                       : root.lookTheme.amber
                opacity: actionAllowed ? 1.0 : 0.35

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
                    Accessible.onPressAction: root.backend && typeof root.backend.playPause === "function" && root.backend.playPause()
                    anchors.fill: parent
                    enabled: playBtn.actionAllowed
                    hoverEnabled: true
                    cursorShape: playBtn.actionAllowed ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        if (root.backend && typeof root.backend.playPause === "function") {
                            root.backend.playPause();
                        }
                    }
                }
            }

            Rectangle {
                id: nextBtn
                readonly property bool actionAllowed: root.mediaAvailable && root.canGoNext
                Layout.preferredWidth: 32
                Layout.preferredHeight: 32
                radius: 10
                color: nextMouse.containsMouse && actionAllowed ? root.lookTheme.surfaceAlt : root.lookTheme.cardAlt
                opacity: actionAllowed ? 1.0 : 0.35

                Behavior on color {
                    ColorAnimation { duration: Kirigami.Units.shortDuration }
                }

                Glyph {
                    anchors.centerIn: parent
                    name: "media-skip-forward-symbolic"
                    size: 14
                    color: root.lookTheme.text
                }

                MouseArea {
                    id: nextMouse
                    Accessible.role: Accessible.Button
                    Accessible.name: i18n("Next track")
                    Accessible.onPressAction: root.backend && typeof root.backend.next === "function" && root.backend.next()
                    anchors.fill: parent
                    enabled: nextBtn.actionAllowed
                    hoverEnabled: true
                    cursorShape: nextBtn.actionAllowed ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        if (root.backend && typeof root.backend.next === "function") {
                            root.backend.next();
                        }
                    }
                }
            }
        }
    }
}
