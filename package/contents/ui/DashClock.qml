pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

// Saat + Canlı Hava Durumu Kartı (Open-Meteo anlık sıcaklık, hissedilen, nem/rüzgâr ve 3 günlük tahmin).
Item {
    id: root

    property var backend: null
    property Theme theme: null

    implicitWidth: 152
    implicitHeight: 170

    Theme {
        id: fallbackTheme
    }

    readonly property Theme lookTheme: root.theme !== null ? root.theme : fallbackTheme

    property date currentTime: new Date()
    readonly property var trLocale: Qt.locale()

    function _capitalizeTr(str: string): string {
        if (!str || str.length === 0) {
            return "";
        }
        const first = str.charAt(0);
        const upper = (first === "i" && root.trLocale.name.startsWith("tr")) ? "İ" : (first === "ı" ? "I" : first.toUpperCase());
        return upper + str.slice(1);
    }

    readonly property string timeText: trLocale.toString(currentTime, "HH:mm")
    readonly property string weekdayText: _capitalizeTr(trLocale.toString(currentTime, "ddd").replace(/\./g, ""))
    readonly property string dayMonthText: trLocale.toString(currentTime, "d") + " " + _capitalizeTr(trLocale.toString(currentTime, "MMM").replace(/\./g, ""))

    // live_ctl.py hava açıklamasını anahtar olarak döndürür; eski önbellekteki düz metin olduğu gibi gösterilir.
    function weatherText(key: string): string {
        switch (key) {
        case "clear": return i18nc("weather", "Clear");
        case "partly_cloudy": return i18nc("weather", "Partly cloudy");
        case "cloudy": return i18nc("weather", "Cloudy");
        case "fog": return i18nc("weather", "Foggy");
        case "drizzle": return i18nc("weather", "Drizzle");
        case "rain": return i18nc("weather", "Rainy");
        case "snow": return i18nc("weather", "Snowy");
        case "storm": return i18nc("weather", "Stormy");
        case "loading": return i18n("Loading…");
        case "offline": return i18n("Offline");
        case "no_location": return i18n("Location not set");
        }
        return key;
    }

    function dayLabel(day: var): string {
        if (!day) {
            return "";
        }
        if (day.day === "today") {
            return i18n("Today");
        }
        if (day.dow !== undefined) {
            return _capitalizeTr(trLocale.dayName(Number(day.dow), Locale.ShortFormat).replace(/\./g, ""));
        }
        return day.day ? String(day.day) : "";
    }

    readonly property bool weatherAvail: Boolean(root.backend && root.backend.weatherAvailable)
    readonly property string weatherCity: (root.backend && root.backend.weatherCity) ? String(root.backend.weatherCity) : ""
    readonly property int weatherTemp: (root.backend && root.backend.weatherTemp !== undefined) ? Number(root.backend.weatherTemp) : 0
    readonly property int weatherFeels: (root.backend && root.backend.weatherFeelsLike !== undefined) ? Number(root.backend.weatherFeelsLike) : 0
    readonly property int weatherHumidity: (root.backend && root.backend.weatherHumidity !== undefined) ? Number(root.backend.weatherHumidity) : 0
    readonly property int weatherWind: (root.backend && root.backend.weatherWind !== undefined) ? Number(root.backend.weatherWind) : 0
    readonly property string weatherDesc: (root.backend && root.backend.weatherDesc) ? String(root.backend.weatherDesc) : "loading"
    readonly property string weatherIcon: (root.backend && root.backend.weatherIcon) ? String(root.backend.weatherIcon) : "weather-few-clouds-symbolic"
    readonly property var weatherDaily: (root.backend && Array.isArray(root.backend.weatherDaily)) ? root.backend.weatherDaily.slice(0, 3) : []

    Timer {
        interval: 15000
        repeat: true
        running: root.visible
        triggeredOnStart: true
        onTriggered: {
            root.currentTime = new Date();
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 5

        // 1. Üst Saat & Tarih satırı
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Text {
                text: root.timeText
                textFormat: Text.PlainText
                color: root.lookTheme.text
                font.family: root.lookTheme.monoFamily
                font.pixelSize: 22
                font.weight: Font.Bold
            }

            Item {
                Layout.fillWidth: true
            }

            Column {
                spacing: 0
                Layout.alignment: Qt.AlignVCenter

                Text {
                    anchors.right: parent.right
                    text: root.weekdayText
                    textFormat: Text.PlainText
                    color: root.lookTheme.amber
                    font.family: root.lookTheme.fontFamily
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                }

                Text {
                    anchors.right: parent.right
                    text: root.dayMonthText
                    textFormat: Text.PlainText
                    color: root.lookTheme.subtext
                    font.family: root.lookTheme.monoFamily
                    font.pixelSize: 10
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: root.lookTheme.divider
        }

        // 2. Orta: Anlık Hava Durumu (Sıcaklık + Durum + Şehir + Nem/Rüzgâr); ayarda kapalıysa gizli
        Item {
            visible: Boolean(root.backend && root.backend.weatherEnabled)
            Layout.fillWidth: true
            Layout.preferredHeight: 48

            RowLayout {
                anchors.fill: parent
                spacing: 8

                Glyph {
                    name: root.weatherIcon
                    size: 24
                    color: root.lookTheme.amber
                    Layout.alignment: Qt.AlignVCenter
                }

                Text {
                    text: root.weatherAvail ? (String(root.weatherTemp) + "°") : "--°"
                    textFormat: Text.PlainText
                    color: root.lookTheme.text
                    font.family: root.lookTheme.monoFamily
                    font.pixelSize: 22
                    font.weight: Font.Bold
                    Layout.alignment: Qt.AlignVCenter
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 1

                    Text {
                        Layout.fillWidth: true
                        text: root.weatherAvail ? root.weatherText(root.weatherDesc) : i18n("Weather")
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        color: root.lookTheme.text
                        font.family: root.lookTheme.fontFamily
                        font.pixelSize: 10
                        font.weight: Font.DemiBold
                    }

                    Text {
                        Layout.fillWidth: true
                        text: root.weatherAvail
                              ? ((root.weatherCity !== "" ? root.weatherCity + " · " : "") + i18n("%1% humidity", root.weatherHumidity))
                              : i18n("Click to refresh")
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        color: root.lookTheme.subtext
                        font.family: root.lookTheme.fontFamily
                        font.pixelSize: 9
                    }
                }
            }

            MouseArea {
                Accessible.role: Accessible.Button
                Accessible.name: i18n("Refresh weather")
                Accessible.onPressAction: root.backend && typeof root.backend.refreshWeather === "function" && root.backend.refreshWeather()
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (root.backend && typeof root.backend.refreshWeather === "function") {
                        root.backend.refreshWeather();
                    }
                }
            }
        }

        Item {
            Layout.fillHeight: true
        }

        // 3. Alt: 3 Günlük Mini Tahmin Şeridi (Bugün / Yarın / Ertesi)
        RowLayout {
            Layout.fillWidth: true
            visible: root.weatherDaily.length > 0 && Boolean(root.backend && root.backend.weatherEnabled)
            spacing: 4

            Repeater {
                model: root.weatherDaily

                delegate: Rectangle {
                    id: dayCell
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 34
                    radius: 8
                    color: root.lookTheme.cardAlt

                    Column {
                        anchors.centerIn: parent
                        spacing: 1

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: root.dayLabel(dayCell.modelData)
                            textFormat: Text.PlainText
                            color: root.lookTheme.subtext
                            font.family: root.lookTheme.fontFamily
                            font.pixelSize: 8
                            font.weight: Font.DemiBold
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: (dayCell.modelData && dayCell.modelData.max !== undefined ? String(dayCell.modelData.max) + "°" : "")
                                  + "/"
                                  + (dayCell.modelData && dayCell.modelData.min !== undefined ? String(dayCell.modelData.min) + "°" : "")
                            textFormat: Text.PlainText
                            color: root.lookTheme.text
                            font.family: root.lookTheme.monoFamily
                            font.pixelSize: 8
                            font.weight: Font.Medium
                        }
                    }
                }
            }
        }
    }
}
