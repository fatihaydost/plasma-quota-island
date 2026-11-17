pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami

// Ortak dairesel Canvas göstergesi (Caelestia halkası). value: 0..1, <0 ise ölçüm yok (yalnız iz).
Item {
    id: root

    property real value: 0.0
    property int size: 44
    property real thickness: 4
    property color color: "#fabd2f"
    property color trackColor: "#17ebdbb2"
    // 360 = tam halka, 270 = altı açık kadran
    property real sweep: 360
    // Merkez noktası halkayla AYNI Canvas'ta çizilir: ayrı Rectangle + anchors.centerIn tek sayılı
    // boyutta bütün piksele yuvarlanır (alignWhenCentered) ve Canvas merkezinden 0,5px kayar.
    property real dotSize: 0
    property color dotColor: "transparent"
    default property alias content: centerItem.data

    property real shown: Math.max(0.0, Math.min(1.0, value))

    implicitWidth: size
    implicitHeight: size

    Behavior on shown {
        NumberAnimation { duration: Kirigami.Units.veryLongDuration; easing.type: Easing.OutCubic }
    }

    onShownChanged: canvas.requestPaint()
    onColorChanged: canvas.requestPaint()
    onTrackColorChanged: canvas.requestPaint()
    onDotSizeChanged: canvas.requestPaint()
    onDotColorChanged: canvas.requestPaint()

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const cx = width / 2;
            const cy = height / 2;
            if (root.dotSize > 0) {
                ctx.fillStyle = root.dotColor;
                ctx.beginPath();
                ctx.arc(cx, cy, root.dotSize / 2, 0, 2 * Math.PI, false);
                ctx.fill();
            }
            const r = Math.min(width, height) / 2 - root.thickness / 2;
            if (r <= 0) {
                return;
            }
            const span = root.sweep * Math.PI / 180;
            const start = -Math.PI / 2 - (root.sweep >= 360 ? 0 : span / 2);
            ctx.lineWidth = root.thickness;
            ctx.lineCap = "round";
            ctx.strokeStyle = root.trackColor;
            ctx.beginPath();
            ctx.arc(cx, cy, r, start, start + span, false);
            ctx.stroke();
            if (root.shown > 0.004) {
                ctx.strokeStyle = root.color;
                ctx.beginPath();
                ctx.arc(cx, cy, r, start, start + span * root.shown, false);
                ctx.stroke();
            }
        }
    }

    Item {
        id: centerItem
        anchors.fill: parent
    }
}
