pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami

// Ortak yüzey: obsidyen gövde + 1px sıcak krem iç rim + üstten ışık kırılması.
Rectangle {
    id: root

    property Theme theme: null
    property bool highlighted: false
    property color rimColor: theme ? (highlighted ? theme.rimStrong : theme.rim) : "#22ebdbb2"
    property bool sheen: true
    // true: yarı saydam cam gövde (panel kapsülü)
    property bool glass: false
    default property alias content: contentItem.data

    color: theme ? (glass ? theme.glassPill : theme.obsidian) : "#141617"
    radius: theme ? theme.radiusMedium : 12
    border.width: 1
    border.color: Qt.rgba(0, 0, 0, 0.55)

    Behavior on color {
        ColorAnimation { duration: Kirigami.Units.shortDuration }
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        radius: Math.max(0, root.radius - 1)
        visible: root.sheen
        gradient: Gradient {
            GradientStop { position: 0.0; color: root.theme ? root.theme.sheen : "#0eebdbb2" }
            GradientStop { position: 0.55; color: "transparent" }
        }
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        radius: Math.max(0, root.radius - 1)
        color: "transparent"
        border.width: 1
        border.color: root.rimColor

        Behavior on border.color {
            ColorAnimation { duration: Kirigami.Units.shortDuration }
        }
    }

    Item {
        id: contentItem
        anchors.fill: parent
    }
}
