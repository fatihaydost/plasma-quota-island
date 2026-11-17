pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami
import QtQuick.Controls
import QtQuick.Layouts

// Aylık takvim: Pazartesi başlangıçlı Türkçe aylık takvim, sabit 6 satırlı ızgara ve 140ms opaklık geçişi.
Item {
    id: root

    property var backend: null
    property Theme theme: null

    implicitWidth: 210
    implicitHeight: 224

    Theme {
        id: fallbackTheme
    }

    readonly property Theme lookTheme: root.theme !== null ? root.theme : fallbackTheme
    readonly property var trLocale: Qt.locale()

    property date todayDate: new Date()
    property int displayYear: todayDate.getFullYear()
    property int displayMonth: todayDate.getMonth()
    property int wheelAccum: 0

    readonly property bool isCurrentMonth: displayYear === todayDate.getFullYear()
                                        && displayMonth === todayDate.getMonth()

    function _capitalizeTr(str: string): string {
        if (!str || str.length === 0) {
            return "";
        }
        const first = str.charAt(0);
        const upper = (first === "i" && root.trLocale.name.startsWith("tr")) ? "İ" : (first === "ı" ? "I" : first.toUpperCase());
        return upper + str.slice(1);
    }

    readonly property string monthNameText: _capitalizeTr(
        trLocale.standaloneMonthName(displayMonth, Locale.LongFormat)
    )

    function stepMonth(deltaMonths: int): void {
        if (deltaMonths === 0) {
            return;
        }
        const target = new Date(root.displayYear, root.displayMonth + deltaMonths, 1);
        root.displayYear = target.getFullYear();
        root.displayMonth = target.getMonth();
        fadeInAnim.restart();
    }

    function resetToToday(): void {
        const now = new Date();
        root.todayDate = now;
        if (root.displayYear === now.getFullYear() && root.displayMonth === now.getMonth()) {
            return;
        }
        root.displayYear = now.getFullYear();
        root.displayMonth = now.getMonth();
        fadeInAnim.restart();
    }

    Timer {
        interval: 60000
        repeat: true
        running: root.visible
        triggeredOnStart: true
        onTriggered: {
            const now = new Date();
            const wasToday = root.isCurrentMonth;
            root.todayDate = now;
            if (wasToday) {
                root.displayYear = now.getFullYear();
                root.displayMonth = now.getMonth();
            }
        }
    }

    NumberAnimation {
        id: fadeInAnim
        target: gridFadeWrap
        property: "opacity"
        from: 0.2
        to: 1.0
        duration: Kirigami.Units.shortDuration
        easing.type: Easing.OutCubic
    }

    // Tekerlek ile ay değiştirme ve orta tık ile bugüne dönme
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.MiddleButton
        onClicked: (mouse) => {
            if (mouse.button === Qt.MiddleButton) {
                root.resetToToday();
            }
        }
        onWheel: (wheel) => {
            root.wheelAccum += wheel.angleDelta.y;
            const threshold = 120;
            if (Math.abs(root.wheelAccum) >= threshold) {
                const steps = Math.trunc(root.wheelAccum / threshold);
                root.wheelAccum -= steps * threshold;
                root.stepMonth(steps > 0 ? -1 : 1);
            }
            wheel.accepted = true;
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 4

        // Üst gezinme satırı: önceki ay / Ay Yıl (bugüne dön) / sonraki ay
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 24
            spacing: 4

            Rectangle {
                id: prevMonthBtn
                Layout.preferredWidth: 24
                Layout.preferredHeight: 24
                radius: 12
                border.width: 0
                color: (prevMonthHover.hovered || activeFocus) ? root.lookTheme.cardAlt : "transparent"
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: i18n("Previous month")

                Behavior on color {
                    ColorAnimation { duration: Kirigami.Units.shortDuration }
                }

                Keys.onReturnPressed: root.stepMonth(-1)
                Keys.onSpacePressed: root.stepMonth(-1)

                HoverHandler {
                    id: prevMonthHover
                }

                Glyph {
                    anchors.centerIn: parent
                    name: "go-previous-symbolic"
                    size: 14
                    color: (prevMonthHover.hovered || prevMonthBtn.activeFocus)
                        ? root.lookTheme.text
                        : root.lookTheme.subtext
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.stepMonth(-1)
                }
            }

            Rectangle {
                id: todayJumpBtn
                Layout.fillWidth: true
                Layout.preferredHeight: 24
                radius: 12
                border.width: 0
                color: (!root.isCurrentMonth && (todayHover.hovered || activeFocus))
                    ? root.lookTheme.cardAlt
                    : "transparent"
                activeFocusOnTab: !root.isCurrentMonth
                Accessible.role: Accessible.Button
                Accessible.name: root.monthNameText + " " + root.displayYear

                Behavior on color {
                    ColorAnimation { duration: Kirigami.Units.shortDuration }
                }

                Keys.onReturnPressed: root.resetToToday()
                Keys.onSpacePressed: root.resetToToday()

                HoverHandler {
                    id: todayHover
                }

                Row {
                    anchors.centerIn: parent
                    spacing: 5

                    Text {
                        id: monthLabel
                        text: root.monthNameText
                        textFormat: Text.PlainText
                        color: root.lookTheme.amber
                        font.family: root.lookTheme.fontFamily
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                    }

                    Text {
                        text: String(root.displayYear)
                        textFormat: Text.PlainText
                        color: root.lookTheme.amber
                        font.family: root.lookTheme.monoFamily
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        anchors.baseline: monthLabel.baseline
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: root.isCurrentMonth ? Qt.ArrowCursor : Qt.PointingHandCursor
                    onClicked: root.resetToToday()
                }
            }

            Rectangle {
                id: nextMonthBtn
                Layout.preferredWidth: 24
                Layout.preferredHeight: 24
                radius: 12
                border.width: 0
                color: (nextMonthHover.hovered || activeFocus) ? root.lookTheme.cardAlt : "transparent"
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: i18n("Next month")

                Behavior on color {
                    ColorAnimation { duration: Kirigami.Units.shortDuration }
                }

                Keys.onReturnPressed: root.stepMonth(1)
                Keys.onSpacePressed: root.stepMonth(1)

                HoverHandler {
                    id: nextMonthHover
                }

                Glyph {
                    anchors.centerIn: parent
                    name: "go-next-symbolic"
                    size: 14
                    color: (nextMonthHover.hovered || nextMonthBtn.activeFocus)
                        ? root.lookTheme.text
                        : root.lookTheme.subtext
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.stepMonth(1)
                }
            }
        }

        // Haftanın günleri başlık satırı (Pazartesi başlar)
        DayOfWeekRow {
            id: weekHeader
            Layout.fillWidth: true
            Layout.preferredHeight: 16
            locale: root.trLocale
            spacing: 0

            delegate: Text {
                required property string shortName

                text: shortName.replace(/\./g, "").slice(0, 3)
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                color: root.lookTheme.mutedText
                font.family: root.lookTheme.fontFamily
                font.pixelSize: 10
                font.weight: Font.Medium
            }
        }

        // Sabit yükseklikli 6 satırlık ay ızgarası
        Item {
            id: gridFadeWrap
            Layout.fillWidth: true
            Layout.fillHeight: true

            MonthGrid {
                id: monthGrid
                anchors.fill: parent
                month: root.displayMonth
                year: root.displayYear
                locale: root.trLocale
                spacing: 0

                delegate: Item {
                    id: dayCell

                    required property var model

                    readonly property bool isTodayCell: Boolean(dayCell.model.today)
                    readonly property bool inActiveMonth: dayCell.model.month === monthGrid.month
                    readonly property int weekdayIndex: dayCell.model.date ? dayCell.model.date.getDay() : -1
                    readonly property bool isWeekend: weekdayIndex === 0 || weekdayIndex === 6

                    Rectangle {
                        width: 22
                        height: 22
                        radius: 11
                        border.width: 0
                        anchors.centerIn: parent
                        color: root.lookTheme.amber
                        visible: dayCell.isTodayCell
                    }

                    Text {
                        anchors.centerIn: parent
                        text: String(dayCell.model.day)
                        textFormat: Text.PlainText
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        font.family: root.lookTheme.monoFamily
                        font.pixelSize: 11
                        font.weight: dayCell.isTodayCell ? Font.DemiBold : Font.Normal
                        color: dayCell.isTodayCell
                            ? root.lookTheme.obsidian
                            : (dayCell.isWeekend ? root.lookTheme.aqua : root.lookTheme.text)
                        opacity: (dayCell.isTodayCell || dayCell.inActiveMonth) ? 1.0 : 0.35
                    }
                }
            }
        }
    }
}
