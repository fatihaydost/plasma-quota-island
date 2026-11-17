pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami
import QtQuick.Layouts

// Quota Island — Ses ve çıkış yönetimi (saydam gövde; TonalCard FullIsland tarafından sarılır).
Item {
    id: root

    property var backend: null
    property Theme theme: null
    property bool compact: false
    property int volumeStep: 5

    Theme {
        id: fallbackTheme
    }

    readonly property Theme lookTheme: root.theme !== null ? root.theme : fallbackTheme

    readonly property int rawVolume: (root.backend && root.backend.volume !== undefined)
                                     ? Math.max(0, Math.min(150, Math.round(Number(root.backend.volume)))) : 0
    readonly property bool muted: Boolean(root.backend && root.backend.muted)
    readonly property string currentSinkId: (root.backend && root.backend.sinkId !== undefined)
                                            ? String(root.backend.sinkId) : ""
    readonly property string currentSinkName: (root.backend && root.backend.sinkName)
                                              ? String(root.backend.sinkName) : ""
    readonly property int sourceVolume: (root.backend && root.backend.sourceVolume !== undefined)
                                        ? Math.max(0, Math.min(150, Math.round(Number(root.backend.sourceVolume)))) : 100
    readonly property bool sourceMuted: Boolean(root.backend && root.backend.sourceMuted)
    readonly property var sinksList: (root.backend && Array.isArray(root.backend.sinks)) ? root.backend.sinks : []
    readonly property var streamsList: (root.backend && Array.isArray(root.backend.streams)) ? root.backend.streams : []

    property bool draggingMaster: false
    property int masterPreviewVol: -1
    property bool sinksExpanded: true

    readonly property int effectiveVolume: (root.draggingMaster || root.masterPreviewVol >= 0)
                                           ? root.masterPreviewVol : root.rawVolume
    readonly property real masterRatio: Math.max(0.0, Math.min(1.0, root.effectiveVolume / 150.0))

    readonly property color masterGaugeColor: root.muted
                                              ? root.lookTheme.coral
                                              : (root.effectiveVolume > 100 ? root.lookTheme.orange : root.lookTheme.amber)

    readonly property string speakerGlyphName: {
        if (root.muted || root.effectiveVolume === 0) {
            return "audio-volume-muted-symbolic";
        }
        if (root.effectiveVolume >= 70) {
            return "audio-volume-high-symbolic";
        }
        if (root.effectiveVolume >= 30) {
            return "audio-volume-medium-symbolic";
        }
        return "audio-volume-low-symbolic";
    }

    function clampVolume(val: real, snapHundred: bool): int {
        let rounded = Math.max(0, Math.min(150, Math.round(val)));
        if (snapHundred && rounded >= 98 && rounded <= 102) {
            rounded = 100;
        }
        return rounded;
    }

    function sendMasterVolume(vol: int): void {
        const clamped = Math.max(0, Math.min(150, vol));
        if (root.backend && typeof root.backend.setVolume === "function") {
            root.backend.setVolume(clamped);
        }
    }

    function stepMasterVolume(delta: int): void {
        const nextVol = Math.max(0, Math.min(150, root.effectiveVolume + delta));
        root.masterPreviewVol = nextVol;
        masterHoldTimer.restart();
        root.sendMasterVolume(nextVol);
    }

    function triggerToggleMute(): void {
        if (root.backend && typeof root.backend.toggleMute === "function") {
            root.backend.toggleMute();
        }
    }

    function triggerToggleMic(): void {
        if (root.backend && typeof root.backend.toggleMic === "function") {
            root.backend.toggleMic();
        }
    }

    function triggerSetSink(idStr: string): void {
        if (idStr !== "" && root.backend && typeof root.backend.setSink === "function") {
            root.backend.setSink(idStr);
        }
    }

    function triggerSetStreamVolume(streamId: string, vol: int): void {
        const clamped = Math.max(0, Math.min(150, vol));
        if (streamId !== "" && root.backend && typeof root.backend.setStreamVolume === "function") {
            root.backend.setStreamVolume(streamId, clamped);
        }
    }

    function triggerToggleStreamMute(streamId: string): void {
        if (streamId !== "" && root.backend && typeof root.backend.toggleStreamMute === "function") {
            root.backend.toggleStreamMute(streamId);
        }
    }

    Timer {
        id: masterThrottleTimer
        interval: 150
        repeat: false
        onTriggered: {
            if (root.masterPreviewVol >= 0) {
                root.sendMasterVolume(root.masterPreviewVol);
            }
        }
    }

    Timer {
        id: masterHoldTimer
        interval: 750
        repeat: false
        onTriggered: {
            if (!root.draggingMaster) {
                root.masterPreviewVol = -1;
            }
        }
    }

    implicitWidth: 254
    implicitHeight: 298

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        // Üst: 64px ana ses halkası + kaydırıcı + mute ve mikrofon düğmeleri
        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            RingGauge {
                Layout.alignment: Qt.AlignVCenter
                size: 64
                thickness: 5
                sweep: 270
                value: root.masterRatio
                color: root.masterGaugeColor
                trackColor: root.lookTheme.track

                Row {
                    anchors.centerIn: parent
                    spacing: 1

                    Text {
                        text: String(root.effectiveVolume)
                        textFormat: Text.PlainText
                        font.family: root.lookTheme.monoFamily
                        font.pixelSize: 15
                        font.weight: Font.Bold
                        color: root.muted
                               ? root.lookTheme.coral
                               : (root.effectiveVolume > 100 ? root.lookTheme.orange : root.lookTheme.text)
                    }

                    Text {
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 2
                        text: "%"
                        textFormat: Text.PlainText
                        font.family: root.lookTheme.monoFamily
                        font.pixelSize: 10
                        color: root.lookTheme.mutedText
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    onWheel: (wheel) => {
                        const step = Math.max(1, root.volumeStep);
                        if (wheel.angleDelta.y > 0) {
                            root.stepMasterVolume(step);
                        } else if (wheel.angleDelta.y < 0) {
                            root.stepMasterVolume(-step);
                        }
                        wheel.accepted = true;
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    Text {
                        Layout.fillWidth: true
                        text: root.currentSinkName !== "" ? root.currentSinkName : i18n("Audio")
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        font.family: root.lookTheme.fontFamily
                        font.pixelSize: root.lookTheme.fontBody
                        font.weight: Font.DemiBold
                        color: root.lookTheme.text
                    }

                    // Hoparlör mute düğmesi (28x28, çerçevesiz)
                    Rectangle {
                        id: mutePill
                        Layout.preferredWidth: 28
                        Layout.preferredHeight: 28
                        radius: 14
                        color: root.muted
                               ? root.lookTheme.tint(root.lookTheme.coral, 0.16)
                               : ((muteMouse.containsMouse || mutePill.activeFocus) ? root.lookTheme.surface : root.lookTheme.cardAlt)
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: root.muted ? i18n("Unmute") : i18n("Mute")

                        Behavior on color {
                            ColorAnimation { duration: Kirigami.Units.shortDuration }
                        }

                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                root.triggerToggleMute();
                                event.accepted = true;
                            }
                        }

                        Glyph {
                            anchors.centerIn: parent
                            name: root.speakerGlyphName
                            size: 14
                            color: root.muted
                                   ? root.lookTheme.coral
                                   : (mutePill.activeFocus ? root.lookTheme.amber : root.lookTheme.text)
                        }

                        MouseArea {
                            id: muteMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: (mouse) => {
                                mouse.accepted = true;
                                mutePill.forceActiveFocus();
                                root.triggerToggleMute();
                            }
                            onWheel: (wheel) => {
                                const step = Math.max(1, root.volumeStep);
                                if (wheel.angleDelta.y > 0) {
                                    root.stepMasterVolume(step);
                                } else if (wheel.angleDelta.y < 0) {
                                    root.stepMasterVolume(-step);
                                }
                                wheel.accepted = true;
                            }
                        }
                    }

                    // Mikrofon mute düğmesi (28x28, çerçevesiz)
                    Rectangle {
                        id: micPill
                        Layout.preferredWidth: 28
                        Layout.preferredHeight: 28
                        radius: 14
                        color: root.sourceMuted
                               ? root.lookTheme.tint(root.lookTheme.coral, 0.16)
                               : ((micMouse.containsMouse || micPill.activeFocus) ? root.lookTheme.surface : root.lookTheme.cardAlt)
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: root.sourceMuted ? i18n("Unmute microphone") : i18n("Mute microphone")

                        Behavior on color {
                            ColorAnimation { duration: Kirigami.Units.shortDuration }
                        }

                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                root.triggerToggleMic();
                                event.accepted = true;
                            }
                        }

                        Glyph {
                            anchors.centerIn: parent
                            name: root.sourceMuted ? "microphone-sensitivity-muted-symbolic" : "microphone-sensitivity-high-symbolic"
                            size: 14
                            color: root.sourceMuted
                                   ? root.lookTheme.coral
                                   : (micPill.activeFocus ? root.lookTheme.amber : root.lookTheme.text)
                        }

                        MouseArea {
                            id: micMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: (mouse) => {
                                mouse.accepted = true;
                                micPill.forceActiveFocus();
                                root.triggerToggleMic();
                            }
                        }
                    }
                }

                // Sabit 6px kapsül ana ses kaydırıcısı
                Item {
                    id: masterSliderBox
                    Layout.fillWidth: true
                    Layout.preferredHeight: 16
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Slider
                    Accessible.name: i18n("Master volume %1 percent", root.effectiveVolume)

                    Keys.onPressed: (event) => {
                        const step = (event.modifiers & Qt.ShiftModifier) ? 1 : Math.max(1, root.volumeStep);
                        if (event.key === Qt.Key_Left || event.key === Qt.Key_Down) {
                            root.stepMasterVolume(-step);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Up) {
                            root.stepMasterVolume(step);
                            event.accepted = true;
                        }
                    }

                    Rectangle {
                        id: masterTrack
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        height: 6
                        radius: 3
                        color: root.lookTheme.track

                        Rectangle {
                            width: Math.max(0, Math.min(masterTrack.width, Math.round(masterTrack.width * root.masterRatio)))
                            height: parent.height
                            radius: parent.radius
                            color: root.muted
                                   ? root.lookTheme.coral
                                   : (root.effectiveVolume > 100 ? root.lookTheme.orange : root.lookTheme.amberDim)
                            opacity: root.muted ? 0.55 : 1.0

                            Behavior on width {
                                enabled: !root.draggingMaster
                                NumberAnimation {
                                    duration: Kirigami.Units.shortDuration
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }

                        // %100 referans çentiği
                        Rectangle {
                            x: Math.round(masterTrack.width * (100.0 / 150.0))
                            width: 1
                            height: parent.height + 4
                            anchors.verticalCenter: parent.verticalCenter
                            color: root.lookTheme.divider
                        }
                    }

                    Rectangle {
                        width: 12
                        height: 12
                        radius: 6
                        x: Math.max(0, Math.min(masterSliderBox.width - width, Math.round(masterSliderBox.width * root.masterRatio - width / 2)))
                        anchors.verticalCenter: parent.verticalCenter
                        color: masterSliderBox.activeFocus ? root.lookTheme.amber : root.lookTheme.text

                        Behavior on color {
                            ColorAnimation { duration: Kirigami.Units.shortDuration }
                        }
                    }

                    MouseArea {
                        id: masterSliderMouse
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        height: 24
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor

                        function volFromX(posX: real, snap: bool): int {
                            if (masterSliderBox.width <= 0) {
                                return 0;
                            }
                            const ratio = Math.max(0.0, Math.min(1.0, posX / masterSliderBox.width));
                            return root.clampVolume(ratio * 150.0, snap);
                        }

                        onPressed: (mouse) => {
                            masterSliderBox.forceActiveFocus();
                            root.draggingMaster = true;
                            root.masterPreviewVol = volFromX(mouse.x, false);
                            if (!masterThrottleTimer.running) {
                                masterThrottleTimer.start();
                            }
                        }

                        onPositionChanged: (mouse) => {
                            if (pressed && root.draggingMaster) {
                                root.masterPreviewVol = volFromX(mouse.x, true);
                                if (!masterThrottleTimer.running) {
                                    masterThrottleTimer.start();
                                }
                            }
                        }

                        onReleased: (mouse) => {
                            if (!root.draggingMaster) {
                                return;
                            }
                            const finalVol = volFromX(mouse.x, false);
                            root.draggingMaster = false;
                            root.masterPreviewVol = finalVol;
                            masterThrottleTimer.stop();
                            masterHoldTimer.restart();
                            root.sendMasterVolume(finalVol);
                        }

                        onCanceled: {
                            root.draggingMaster = false;
                            masterThrottleTimer.stop();
                            masterHoldTimer.restart();
                        }

                        onWheel: (wheel) => {
                            const step = Math.max(1, root.volumeStep);
                            if (wheel.angleDelta.y > 0) {
                                root.stepMasterVolume(step);
                            } else if (wheel.angleDelta.y < 0) {
                                root.stepMasterVolume(-step);
                            }
                            wheel.accepted = true;
                        }
                    }
                }
            }
        }

        // Çıkış cihazı çipleri (başlıksız Flow; boşsa çizilmez)
        Flow {
            id: sinkFlow
            Layout.fillWidth: true
            visible: !root.compact && root.sinksExpanded && root.sinksList.length > 0
            spacing: 6

            Repeater {
                model: root.sinksList

                delegate: Rectangle {
                    id: sinkChip

                    required property var modelData
                    required property int index

                    readonly property string itemSinkId: (sinkChip.modelData && sinkChip.modelData.id !== undefined)
                                                         ? String(sinkChip.modelData.id) : ""
                    readonly property string itemTitle: (sinkChip.modelData && sinkChip.modelData.description)
                                                        ? String(sinkChip.modelData.description)
                                                        : ((sinkChip.modelData && sinkChip.modelData.name)
                                                           ? String(sinkChip.modelData.name)
                                                           : i18n("Output %1", sinkChip.index + 1))
                    readonly property bool isCurrent: root.currentSinkId !== ""
                                                      ? (sinkChip.itemSinkId === root.currentSinkId)
                                                      : Boolean(sinkChip.modelData && sinkChip.modelData.isDefault)

                    width: Math.min(Math.max(96, sinkFlow.width), sinkChipRow.implicitWidth + 18)
                    height: 26
                    radius: 13
                    color: sinkChip.isCurrent
                           ? root.lookTheme.surfaceAlt
                           : ((sinkItemMouse.containsMouse || sinkChip.activeFocus) ? root.lookTheme.surface : root.lookTheme.cardAlt)

                    Behavior on color {
                        ColorAnimation { duration: Kirigami.Units.shortDuration }
                    }

                    activeFocusOnTab: !root.compact
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: sinkChip.itemTitle

                    Keys.onPressed: (event) => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                            root.triggerSetSink(sinkChip.itemSinkId);
                            event.accepted = true;
                        }
                    }

                    RowLayout {
                        id: sinkChipRow
                        anchors.fill: parent
                        anchors.leftMargin: 9
                        anchors.rightMargin: 9
                        spacing: 5

                        Glyph {
                            visible: sinkChip.isCurrent
                            name: "emblem-ok-symbolic"
                            size: 12
                            color: root.lookTheme.amber
                        }

                        Text {
                            Layout.fillWidth: true
                            text: sinkChip.itemTitle
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            font.family: root.lookTheme.fontFamily
                            font.pixelSize: 11
                            font.weight: sinkChip.isCurrent ? Font.DemiBold : Font.Normal
                            color: sinkChip.isCurrent
                                   ? root.lookTheme.amber
                                   : (sinkItemMouse.containsMouse ? root.lookTheme.text : root.lookTheme.subtext)

                            Behavior on color {
                                ColorAnimation { duration: Kirigami.Units.shortDuration }
                            }
                        }
                    }

                    MouseArea {
                        id: sinkItemMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: (mouse) => {
                            mouse.accepted = true;
                            sinkChip.forceActiveFocus();
                            root.triggerSetSink(sinkChip.itemSinkId);
                        }
                    }
                }
            }
        }

        // Uygulama ses akışları (başlıksız, tek sütun ince satırlar; sığmazsa yalnız bu liste kayar)
        Flickable {
            id: streamsFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !root.compact && root.streamsList.length > 0
            contentWidth: width
            contentHeight: streamsCol.implicitHeight
            interactive: contentHeight > height + 1
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: streamsCol
                width: streamsFlick.width
                spacing: 6

                Repeater {
                    model: root.streamsList

                    delegate: TonalCard {
                        id: streamCard

                        required property var modelData
                        required property int index

                        readonly property string streamId: (streamCard.modelData && streamCard.modelData.id !== undefined)
                                                           ? String(streamCard.modelData.id) : ""
                        readonly property string appName: (streamCard.modelData && streamCard.modelData.appName)
                                                          ? String(streamCard.modelData.appName)
                                                          : i18n("Application %1", streamCard.index + 1)
                        readonly property int rawStreamVol: (streamCard.modelData && streamCard.modelData.volume !== undefined)
                                                            ? Math.max(0, Math.min(150, Math.round(Number(streamCard.modelData.volume)))) : 100
                        readonly property bool streamMuted: Boolean(streamCard.modelData && streamCard.modelData.muted)

                        property bool streamDragging: false
                        property int streamPreviewVol: -1

                        readonly property int effectiveStreamVol: (streamCard.streamDragging || streamCard.streamPreviewVol >= 0)
                                                                  ? streamCard.streamPreviewVol : streamCard.rawStreamVol
                        readonly property real streamRatio: Math.max(0.0, Math.min(1.0, streamCard.effectiveStreamVol / 150.0))

                        function stepStream(delta: int): void {
                            const nextVal = Math.max(0, Math.min(150, streamCard.effectiveStreamVol + delta));
                            streamCard.streamPreviewVol = nextVal;
                            streamHoldTimer.restart();
                            root.triggerSetStreamVolume(streamCard.streamId, nextVal);
                        }

                        Timer {
                            id: streamThrottleTimer
                            interval: 150
                            repeat: false
                            onTriggered: {
                                if (streamCard.streamPreviewVol >= 0) {
                                    root.triggerSetStreamVolume(streamCard.streamId, streamCard.streamPreviewVol);
                                }
                            }
                        }

                        Timer {
                            id: streamHoldTimer
                            interval: 750
                            repeat: false
                            onTriggered: {
                                if (!streamCard.streamDragging) {
                                    streamCard.streamPreviewVol = -1;
                                }
                            }
                        }

                        theme: root.lookTheme
                        alt: true
                        radius: 12
                        Layout.fillWidth: true
                        implicitHeight: 46

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            anchors.topMargin: 6
                            anchors.bottomMargin: 6
                            spacing: 4

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                Text {
                                    Layout.fillWidth: true
                                    text: streamCard.appName
                                    textFormat: Text.PlainText
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                    font.family: root.lookTheme.fontFamily
                                    font.pixelSize: 11
                                    font.weight: Font.Medium
                                    color: root.lookTheme.text
                                }

                                Row {
                                    spacing: 1

                                    Text {
                                        text: String(streamCard.effectiveStreamVol)
                                        textFormat: Text.PlainText
                                        font.family: root.lookTheme.monoFamily
                                        font.pixelSize: root.lookTheme.fontSmall
                                        font.weight: Font.DemiBold
                                        color: streamCard.streamMuted
                                               ? root.lookTheme.coral
                                               : (streamCard.effectiveStreamVol > 100 ? root.lookTheme.orange : root.lookTheme.text)
                                    }

                                    Text {
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: 1
                                        text: "%"
                                        textFormat: Text.PlainText
                                        font.family: root.lookTheme.monoFamily
                                        font.pixelSize: 8
                                        color: root.lookTheme.mutedText
                                    }
                                }

                                Rectangle {
                                    id: streamMuteBtn
                                    Layout.preferredWidth: 20
                                    Layout.preferredHeight: 20
                                    radius: 10
                                    color: streamCard.streamMuted
                                           ? root.lookTheme.tint(root.lookTheme.coral, 0.16)
                                           : ((streamMuteMouse.containsMouse || streamMuteBtn.activeFocus) ? root.lookTheme.surface : "transparent")
                                    activeFocusOnTab: !root.compact
                                    Accessible.role: Accessible.Button
                                    Accessible.name: streamCard.streamMuted ? i18n("Unmute %1", streamCard.appName) : i18n("Mute %1", streamCard.appName)

                                    Behavior on color {
                                        ColorAnimation { duration: Kirigami.Units.shortDuration }
                                    }

                                    Keys.onPressed: (event) => {
                                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                            root.triggerToggleStreamMute(streamCard.streamId);
                                            event.accepted = true;
                                        }
                                    }

                                    Glyph {
                                        anchors.centerIn: parent
                                        name: streamCard.streamMuted ? "audio-volume-muted-symbolic" : "audio-volume-high-symbolic"
                                        size: 12
                                        color: streamCard.streamMuted
                                               ? root.lookTheme.coral
                                               : (streamMuteBtn.activeFocus ? root.lookTheme.amber : root.lookTheme.subtext)
                                    }

                                    MouseArea {
                                        id: streamMuteMouse
                                        anchors.centerIn: parent
                                        width: 24
                                        height: 24
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: (mouse) => {
                                            mouse.accepted = true;
                                            streamMuteBtn.forceActiveFocus();
                                            root.triggerToggleStreamMute(streamCard.streamId);
                                        }
                                    }
                                }
                            }

                            Item {
                                id: streamSliderBox
                                Layout.fillWidth: true
                                Layout.preferredHeight: 10
                                activeFocusOnTab: !root.compact
                                Accessible.role: Accessible.Slider
                                Accessible.name: i18n("%1 volume", streamCard.appName)

                                Keys.onPressed: (event) => {
                                    const step = (event.modifiers & Qt.ShiftModifier) ? 1 : Math.max(1, root.volumeStep);
                                    if (event.key === Qt.Key_Left || event.key === Qt.Key_Down) {
                                        streamCard.stepStream(-step);
                                        event.accepted = true;
                                    } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Up) {
                                        streamCard.stepStream(step);
                                        event.accepted = true;
                                    }
                                }

                                Rectangle {
                                    id: streamTrack
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    height: 4
                                    radius: 2
                                    color: root.lookTheme.track

                                    Rectangle {
                                        width: Math.max(0, Math.min(streamTrack.width, Math.round(streamTrack.width * streamCard.streamRatio)))
                                        height: parent.height
                                        radius: parent.radius
                                        color: streamCard.streamMuted
                                               ? root.lookTheme.coral
                                               : (streamCard.effectiveStreamVol > 100 ? root.lookTheme.orange : root.lookTheme.amberDim)
                                        opacity: streamCard.streamMuted ? 0.5 : 1.0
                                    }
                                }

                                Rectangle {
                                    width: 8
                                    height: 8
                                    radius: 4
                                    x: Math.max(0, Math.min(streamSliderBox.width - width, Math.round(streamSliderBox.width * streamCard.streamRatio - width / 2)))
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: streamSliderBox.activeFocus ? root.lookTheme.amber : root.lookTheme.text
                                    opacity: (streamSliderMouse.containsMouse || streamSliderBox.activeFocus || streamCard.streamDragging) ? 1.0 : 0.0

                                    Behavior on opacity {
                                        NumberAnimation { duration: Kirigami.Units.shortDuration }
                                    }
                                }

                                MouseArea {
                                    id: streamSliderMouse
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    height: 24
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor

                                    function streamVolFromX(posX: real, snap: bool): int {
                                        if (streamSliderBox.width <= 0) {
                                            return 0;
                                        }
                                        const ratio = Math.max(0.0, Math.min(1.0, posX / streamSliderBox.width));
                                        return root.clampVolume(ratio * 150.0, snap);
                                    }

                                    onPressed: (mouse) => {
                                        streamSliderBox.forceActiveFocus();
                                        streamCard.streamDragging = true;
                                        streamCard.streamPreviewVol = streamVolFromX(mouse.x, false);
                                        if (!streamThrottleTimer.running) {
                                            streamThrottleTimer.start();
                                        }
                                    }

                                    onPositionChanged: (mouse) => {
                                        if (pressed && streamCard.streamDragging) {
                                            streamCard.streamPreviewVol = streamVolFromX(mouse.x, true);
                                            if (!streamThrottleTimer.running) {
                                                streamThrottleTimer.start();
                                            }
                                        }
                                    }

                                    onReleased: (mouse) => {
                                        if (!streamCard.streamDragging) {
                                            return;
                                        }
                                        const finalVol = streamVolFromX(mouse.x, false);
                                        streamCard.streamDragging = false;
                                        streamCard.streamPreviewVol = finalVol;
                                        streamThrottleTimer.stop();
                                        streamHoldTimer.restart();
                                        root.triggerSetStreamVolume(streamCard.streamId, finalVol);
                                    }

                                    onCanceled: {
                                        streamCard.streamDragging = false;
                                        streamThrottleTimer.stop();
                                        streamHoldTimer.restart();
                                    }

                                    onWheel: (wheel) => {
                                        const step = Math.max(1, root.volumeStep);
                                        if (wheel.angleDelta.y > 0) {
                                            streamCard.stepStream(step);
                                        } else if (wheel.angleDelta.y < 0) {
                                            streamCard.stepStream(-step);
                                        }
                                        wheel.accepted = true;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        Item {
            visible: root.compact || root.streamsList.length === 0
            Layout.fillHeight: true
        }
    }
}
