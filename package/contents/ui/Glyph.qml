pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami

// Ortak ikon: tek renge boyanan monokrom Kirigami vektörü. Emoji yerine HER YERDE bu kullanılır.
Kirigami.Icon {
    id: root

    property string name: ""
    property int size: 14

    source: name
    isMask: true
    color: "#ebdbb2"
    implicitWidth: size
    implicitHeight: size
    width: size
    height: size
    smooth: true

    Behavior on color {
        ColorAnimation { duration: Kirigami.Units.shortDuration }
    }
}
