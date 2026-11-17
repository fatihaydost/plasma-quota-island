pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami

// Ortak kart: yarı saydam cam yüzey + 1px ince cam kenarlığı (Plasma bulanık zemini üstünde).
Rectangle {
    property Theme theme: null
    property bool alt: false

    color: theme ? (alt ? theme.cardAlt : theme.card) : "#0febdbb2"
    radius: theme ? theme.radiusCard : 20
    border.width: 1
    border.color: theme ? theme.glassBorder : "#14ebdbb2"

    Behavior on color {
        ColorAnimation { duration: Kirigami.Units.shortDuration }
    }
}
