pragma ComponentBehavior: Bound

import QtQuick

// Müzik çalarken merkezde amber, kenarlarda amberDim parlayan; durunca 2px mutedText noktalara dönüşen 4 çubuklu sabit kutulu ekolayzır.
Item {
    id: root

    property Theme theme: null
    property bool active: false
    property bool playing: false
    property bool running: false

    // the popup copy stays visible:true while its window is hidden; gate on the window too
    readonly property bool isAnimating: (active || playing || running) && visible && Window.window !== null && Window.window.visible

    property int barCount: 4
    property real barWidth: 2
    property real barSpacing: 2
    property int minBarHeight: 3
    property int maxBarHeight: 14
    property bool stretchToWidth: false
    property real inactiveOpacity: 0.72

    property color barColor: theme ? theme.amber : "#fabd2f"
    property color edgeBarColor: theme ? theme.amberDim : "#d79921"
    property color inactiveColor: theme ? theme.mutedText : "#7c6f64"
    property color color: barColor

    property real phase: 0.0

    readonly property real effectiveMaxHeight: height > 0 ? height : maxBarHeight
    readonly property real effectiveBarWidth: stretchToWidth && width > 0 && barCount > 0
        ? Math.max(1.5, (width - barSpacing * Math.max(0, barCount - 1)) / barCount)
        : barWidth

    implicitWidth: barCount * barWidth + Math.max(0, barCount - 1) * barSpacing
    implicitHeight: maxBarHeight

    Timer {
        id: animTimer
        interval: 120
        repeat: true
        running: root.isAnimating
        onTriggered: {
            root.phase = (root.phase + 0.64) % 628.3185;
        }
    }

    Row {
        anchors.centerIn: parent
        spacing: root.barSpacing

        Repeater {
            model: root.barCount

            delegate: Item {
                id: slot

                required property int index

                width: root.effectiveBarWidth
                height: root.effectiveMaxHeight

                readonly property real edgeRatio: {
                    if (root.barCount <= 1) {
                        return 0.0;
                    }
                    const half = (root.barCount - 1) / 2.0;
                    return Math.min(1.0, Math.abs(slot.index - half) / half);
                }

                readonly property real idleWaveRatio: {
                    const s1 = Math.sin(slot.index * 0.78 + 0.5);
                    const s2 = Math.cos(slot.index * 1.43 + 1.1);
                    return Math.max(0.20, Math.min(0.88, 0.48 + 0.24 * s1 + 0.16 * s2));
                }

                readonly property real waveRatio: {
                    if (!root.isAnimating) {
                        return root.stretchToWidth ? slot.idleWaveRatio : 0.0;
                    }
                    const w1 = Math.sin(root.phase * (1.08 + (slot.index % 7) * 0.19) + slot.index * 0.85);
                    const w2 = Math.cos(root.phase * (1.72 - (slot.index % 5) * 0.14) + slot.index * 1.90);
                    const envelope = 1.0 - 0.18 * slot.edgeRatio;
                    const raw = (0.54 + 0.30 * w1 + 0.16 * w2) * envelope;
                    return Math.max(0.18, Math.min(1.0, raw));
                }

                readonly property real targetHeight: {
                    if (!root.isAnimating && !root.stretchToWidth) {
                        return Math.min(2, root.effectiveMaxHeight);
                    }
                    const lo = Math.min(Math.max(2, root.minBarHeight), root.effectiveMaxHeight);
                    return Math.max(lo, Math.round(lo + (root.effectiveMaxHeight - lo) * slot.waveRatio));
                }

                readonly property color activeBarColor: Qt.rgba(
                    root.color.r + (root.edgeBarColor.r - root.color.r) * slot.edgeRatio,
                    root.color.g + (root.edgeBarColor.g - root.color.g) * slot.edgeRatio,
                    root.color.b + (root.edgeBarColor.b - root.color.b) * slot.edgeRatio,
                    1.0
                )

                Rectangle {
                    width: root.effectiveBarWidth
                    height: slot.targetHeight
                    radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: (root.isAnimating || root.stretchToWidth) ? slot.activeBarColor : root.inactiveColor
                    opacity: root.isAnimating ? (0.82 + 0.18 * slot.waveRatio) : root.inactiveOpacity

                    // shortcut: tweens only for play/stop transitions; tweening every 120 ms tick kept the panel at 60 fps (~165% CPU)
                    Behavior on height {
                        enabled: !root.isAnimating
                        NumberAnimation {
                            duration: 115
                            easing.type: Easing.InOutSine
                        }
                    }

                    Behavior on color {
                        enabled: !root.isAnimating
                        ColorAnimation {
                            duration: 140
                        }
                    }

                    Behavior on opacity {
                        enabled: !root.isAnimating
                        NumberAnimation {
                            duration: 140
                        }
                    }
                }
            }
        }
    }
}
