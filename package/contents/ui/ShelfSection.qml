pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami
import QtQuick.Layouts

// Quota Island - Dosya ve Metin Rafı Bölümü.
Item {
    id: root

    property var backend: null
    property Theme theme: null
    property bool compact: false

    Theme {
        id: fallbackTheme
    }

    readonly property Theme lookTheme: root.theme !== null ? root.theme : fallbackTheme

    readonly property var shelfItems: {
        if (root.backend && Array.isArray(root.backend.shelfItems)) {
            return root.backend.shelfItems;
        }
        if (root.backend
            && root.backend.liveData
            && root.backend.liveData.shelf
            && Array.isArray(root.backend.liveData.shelf.items)) {
            return root.backend.liveData.shelf.items;
        }
        return [];
    }

    readonly property int itemCount: Array.isArray(root.shelfItems) ? root.shelfItems.length : 0

    property string copiedItemId: ""
    property string openedItemId: ""
    property string dropFeedbackText: ""

    signal itemAdded(string value)
    signal itemOpened(string itemId)
    signal itemCopied(string itemId, string value)
    signal itemRemoved(string itemId)
    signal shelfCleared()

    function kindIcon(kind: string): string {
        if (kind === "dir") {
            return "folder-symbolic";
        }
        if (kind === "file") {
            return "text-x-generic-symbolic";
        }
        if (kind === "url") {
            return "insert-link-symbolic";
        }
        return "edit-paste-symbolic";
    }

    function kindBadgeColor(kind: string): color {
        if (kind === "dir") {
            return root.lookTheme.amber;
        }
        if (kind === "file") {
            return root.lookTheme.text;
        }
        if (kind === "url") {
            return root.lookTheme.aqua;
        }
        return root.lookTheme.purple;
    }

    function refresh(): void {
        if (root.backend) {
            root.backend.refreshLive();
        }
    }

    function addItems(rawValues: var): void {
        if (!Array.isArray(rawValues) || rawValues.length === 0) {
            return;
        }
        let cleaned = [];
        for (let i = 0; i < rawValues.length; ++i) {
            const v = String(rawValues[i] || "").replace(/\0/g, "").trim();
            if (v !== "") {
                cleaned.push(v);
            }
        }
        if (cleaned.length === 0) {
            return;
        }

        if (root.backend) {
            root.backend.shelfAdd(cleaned.length === 1 ? cleaned[0] : cleaned);
            root.dropFeedbackText = i18np("Added to shelf", "%1 items added to shelf", cleaned.length);
            dropFeedbackTimer.restart();
            root.itemAdded(cleaned[0]);
        }
    }

    function addShelfItem(pathOrText: string): void {
        const trimmed = String(pathOrText || "").trim();
        if (trimmed === "") {
            return;
        }
        root.addItems([trimmed]);
    }

    function addItem(pathOrText: string): void {
        root.addShelfItem(pathOrText);
    }

    function openShelfItem(itemId: string): void {
        const sid = String(itemId || "").trim();
        if (!/^[A-Za-z0-9_-]{1,32}$/.test(sid)) {
            return;
        }
        root.openedItemId = sid;
        openedFeedbackTimer.restart();

        if (root.backend) {
            root.backend.shelfOpen(sid);
            root.itemOpened(sid);
        }
    }

    function copyShelfItem(itemId: string, rawValue: string): void {
        const sid = String(itemId || "").trim();
        const val = String(rawValue || "");
        if (val === "") {
            return;
        }

        clipboardHelper.text = val;
        clipboardHelper.selectAll();
        clipboardHelper.copy();

        root.copiedItemId = sid;
        copiedFeedbackTimer.restart();
        root.itemCopied(sid, val);

        if (root.backend) {
            root.backend.shelfCopy(sid);
        }
    }

    function removeShelfItem(itemId: string): void {
        const sid = String(itemId || "").trim();
        if (!/^[A-Za-z0-9_-]{1,32}$/.test(sid)) {
            return;
        }
        if (root.backend) {
            root.backend.shelfRemove(sid);
            root.itemRemoved(sid);
        }
    }

    function clearShelf(): void {
        if (root.itemCount === 0) {
            return;
        }
        if (root.backend) {
            root.backend.shelfClear();
            root.shelfCleared();
        }
    }

    function submitQuickInput(): void {
        const raw = quickInput.text.trim();
        if (raw === "") {
            return;
        }
        quickInput.text = "";
        root.addShelfItem(raw);
    }

    TextEdit {
        id: clipboardHelper
        visible: false
        width: 0
        height: 0
        textFormat: TextEdit.PlainText
    }

    Timer {
        id: copiedFeedbackTimer
        interval: 1200
        repeat: false
        onTriggered: {
            root.copiedItemId = "";
        }
    }

    Timer {
        id: openedFeedbackTimer
        interval: 1100
        repeat: false
        onTriggered: {
            root.openedItemId = "";
        }
    }

    Timer {
        id: dropFeedbackTimer
        interval: 1800
        repeat: false
        onTriggered: {
            root.dropFeedbackText = "";
        }
    }

    implicitWidth: 512
    implicitHeight: 314

    DropArea {
        id: shelfDropArea
        anchors.fill: parent
        onEntered: function(drag) {
            drag.acceptProposedAction();
        }
        onDropped: function(drop) {
            let collected = [];
            if (drop.hasUrls && drop.urls && drop.urls.length > 0) {
                for (let i = 0; i < drop.urls.length; ++i) {
                    const u = String(drop.urls[i]);
                    if (u.trim() !== "") {
                        collected.push(u);
                    }
                }
            } else if (drop.hasText && drop.text && String(drop.text).trim() !== "") {
                collected.push(String(drop.text));
            }
            if (collected.length > 0) {
                root.addItems(collected);
                drop.acceptProposedAction();
            }
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 10

        // ====================================================================
        // SOL SÜTUN: Bırakma + sade giriş TonalCard (~200px)
        // ====================================================================
        TonalCard {
            Layout.preferredWidth: 200
            Layout.fillHeight: true
            theme: root.lookTheme
            color: shelfDropArea.containsDrag
                   ? root.lookTheme.tint(root.lookTheme.amber, 0.10)
                   : root.lookTheme.card

            // Sağ üstte sabit yuvalı tümünü temizle glifi (yalnız öğe varken görünür, boyutu oynamaz)
            Item {
                id: clearBtn
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 12
                width: 24
                height: 24
                enabled: root.itemCount > 0
                activeFocusOnTab: root.itemCount > 0
                Accessible.role: Accessible.Button
                Accessible.name: i18n("Clear all")
                opacity: root.itemCount > 0
                         ? ((clearHover.hovered || clearBtn.activeFocus) ? 1.0 : 0.55)
                         : 0.0

                Behavior on opacity {
                    NumberAnimation { duration: Kirigami.Units.shortDuration }
                }

                Glyph {
                    anchors.centerIn: parent
                    name: "edit-clear-all-symbolic"
                    size: 14
                    color: clearHover.hovered ? root.lookTheme.coral : root.lookTheme.subtext
                }

                HoverHandler {
                    id: clearHover
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: root.itemCount > 0
                    cursorShape: root.itemCount > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.clearShelf()
                }

                Keys.onReturnPressed: root.clearShelf()
                Keys.onSpacePressed: root.clearShelf()
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 12

                Item {
                    Layout.fillHeight: true
                }

                Glyph {
                    Layout.alignment: Qt.AlignHCenter
                    name: root.dropFeedbackText !== "" ? "emblem-ok-symbolic" : "folder-download-symbolic"
                    size: 28
                    color: shelfDropArea.containsDrag
                           ? root.lookTheme.amber
                           : (root.dropFeedbackText !== "" ? root.lookTheme.olive : root.lookTheme.subtext)
                }

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: root.dropFeedbackText !== "" ? root.dropFeedbackText : i18n("Drop here")
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    font.family: root.dropFeedbackText !== "" ? root.lookTheme.monoFamily : root.lookTheme.fontFamily
                    font.pixelSize: 12
                    color: shelfDropArea.containsDrag
                           ? root.lookTheme.amber
                           : (root.dropFeedbackText !== "" ? root.lookTheme.olive : root.lookTheme.subtext)
                }

                Item {
                    Layout.fillHeight: true
                }

                // Çerçevesiz cardAlt kapsül giriş alanı
                TonalCard {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 34
                    theme: root.lookTheme
                    alt: true
                    radius: 17

                    TextInput {
                        id: quickInput
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        verticalAlignment: TextInput.AlignVCenter
                        clip: true
                        activeFocusOnTab: true
                        color: root.lookTheme.text
                        selectionColor: root.lookTheme.amberDim
                        selectedTextColor: root.lookTheme.text
                        font.family: root.lookTheme.fontFamily
                        font.pixelSize: 11
                        onAccepted: root.submitQuickInput()
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        visible: quickInput.text === "" && !quickInput.activeFocus
                        text: i18n("Note or path")
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        font.family: root.lookTheme.fontFamily
                        font.pixelSize: 11
                        color: root.lookTheme.mutedText
                    }
                }
            }
        }

        // ====================================================================
        // SAĞ SÜTUN: TonalCard içinde 44px satırlar veya sade boş durum
        // ====================================================================
        TonalCard {
            Layout.fillWidth: true
            Layout.fillHeight: true
            theme: root.lookTheme

            ColumnLayout {
                anchors.centerIn: parent
                spacing: 8
                visible: root.itemCount === 0

                Glyph {
                    Layout.alignment: Qt.AlignHCenter
                    name: "window-pin-symbolic"
                    size: 24
                    color: root.lookTheme.mutedText
                    opacity: 0.55
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: i18n("Shelf is empty")
                    textFormat: Text.PlainText
                    font.family: root.lookTheme.fontFamily
                    font.pixelSize: 12
                    color: root.lookTheme.mutedText
                }
            }

            Flickable {
                id: shelfFlick
                visible: root.itemCount > 0
                anchors.fill: parent
                anchors.margins: 10
                contentWidth: width
                contentHeight: shelfCol.implicitHeight
                interactive: contentHeight > height + 1
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: shelfCol
                    width: shelfFlick.width
                    spacing: 8

                    Repeater {
                        model: root.shelfItems

                        delegate: TonalCard {
                            id: itemCard

                            required property var modelData
                            required property int index

                            readonly property string itemId: itemCard.modelData && itemCard.modelData.id
                                                             ? String(itemCard.modelData.id) : ""
                            readonly property string itemKind: itemCard.modelData && itemCard.modelData.kind
                                                               ? String(itemCard.modelData.kind) : "text"
                            readonly property string itemLabel: itemCard.modelData && itemCard.modelData.label
                                                                ? String(itemCard.modelData.label) : ""
                            readonly property string itemValue: itemCard.modelData && itemCard.modelData.value
                                                                ? String(itemCard.modelData.value) : ""
                            readonly property bool itemExists: !itemCard.modelData
                                                               || itemCard.modelData.exists === undefined
                                                               || Boolean(itemCard.modelData.exists)
                            readonly property bool isCopied: root.copiedItemId !== ""
                                                             && root.copiedItemId === itemCard.itemId
                            readonly property bool actionsVisible: itemCardHover.hovered
                                                                   || itemCard.activeFocus
                                                                   || copyBtn.activeFocus
                                                                   || removeBtn.activeFocus
                                                                   || itemCard.isCopied

                            Layout.fillWidth: true
                            Layout.preferredHeight: 44
                            implicitHeight: 44
                            theme: root.lookTheme
                            alt: true
                            radius: 14
                            color: (itemCardHover.hovered || itemCard.activeFocus)
                                   ? root.lookTheme.surface
                                   : root.lookTheme.cardAlt
                            activeFocusOnTab: true
                            Accessible.role: Accessible.Button
                            Accessible.name: itemCard.itemLabel

                            HoverHandler {
                                id: itemCardHover
                            }

                            Keys.onReturnPressed: {
                                if (itemCard.itemExists) {
                                    root.openShelfItem(itemCard.itemId);
                                }
                            }
                            Keys.onSpacePressed: {
                                if (itemCard.itemExists) {
                                    root.openShelfItem(itemCard.itemId);
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                enabled: itemCard.itemExists
                                cursorShape: itemCard.itemExists ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: {
                                    itemCard.forceActiveFocus();
                                    root.openShelfItem(itemCard.itemId);
                                }
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 14
                                anchors.rightMargin: 10
                                spacing: 10

                                Glyph {
                                    name: root.kindIcon(itemCard.itemKind)
                                    size: 16
                                    color: itemCard.itemExists
                                           ? root.kindBadgeColor(itemCard.itemKind)
                                           : root.lookTheme.coral
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: itemCard.itemLabel
                                    textFormat: Text.PlainText
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                    font.family: root.lookTheme.fontFamily
                                    font.pixelSize: 12
                                    font.weight: Font.Medium
                                    color: itemCard.itemExists ? root.lookTheme.text : root.lookTheme.coral
                                }

                                // Her zaman sabit yer ayrılmış kopyala/sil glif yuvası (hover yalnız opaklık oynatır)
                                Row {
                                    Layout.preferredWidth: 52
                                    Layout.preferredHeight: 24
                                    spacing: 4
                                    opacity: itemCard.actionsVisible ? 1.0 : 0.0

                                    Behavior on opacity {
                                        NumberAnimation { duration: Kirigami.Units.shortDuration }
                                    }

                                    Rectangle {
                                        id: copyBtn
                                        width: 24
                                        height: 24
                                        radius: 12
                                        activeFocusOnTab: true
                                        Accessible.role: Accessible.Button
                                        Accessible.name: i18n("Copy")
                                        color: copyHover.hovered ? root.lookTheme.surfaceAlt : "transparent"

                                        Behavior on color {
                                            ColorAnimation { duration: Kirigami.Units.shortDuration }
                                        }

                                        Glyph {
                                            anchors.centerIn: parent
                                            name: itemCard.isCopied ? "emblem-ok-symbolic" : "edit-copy-symbolic"
                                            size: 14
                                            color: itemCard.isCopied
                                                   ? root.lookTheme.olive
                                                   : (copyHover.hovered ? root.lookTheme.amber : root.lookTheme.subtext)
                                        }

                                        HoverHandler {
                                            id: copyHover
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            enabled: itemCard.actionsVisible
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: (mouse) => {
                                                mouse.accepted = true;
                                                root.copyShelfItem(itemCard.itemId, itemCard.itemValue);
                                            }
                                        }

                                        Keys.onReturnPressed: root.copyShelfItem(itemCard.itemId, itemCard.itemValue)
                                        Keys.onSpacePressed: root.copyShelfItem(itemCard.itemId, itemCard.itemValue)
                                    }

                                    Rectangle {
                                        id: removeBtn
                                        width: 24
                                        height: 24
                                        radius: 12
                                        activeFocusOnTab: true
                                        Accessible.role: Accessible.Button
                                        Accessible.name: i18n("Remove")
                                        color: removeHover.hovered
                                               ? root.lookTheme.tint(root.lookTheme.coral, 0.16)
                                               : "transparent"

                                        Behavior on color {
                                            ColorAnimation { duration: Kirigami.Units.shortDuration }
                                        }

                                        Glyph {
                                            anchors.centerIn: parent
                                            name: "edit-delete-symbolic"
                                            size: 14
                                            color: removeHover.hovered ? root.lookTheme.coral : root.lookTheme.subtext
                                        }

                                        HoverHandler {
                                            id: removeHover
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            enabled: itemCard.actionsVisible
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: (mouse) => {
                                                mouse.accepted = true;
                                                root.removeShelfItem(itemCard.itemId);
                                            }
                                        }

                                        Keys.onReturnPressed: root.removeShelfItem(itemCard.itemId)
                                        Keys.onSpacePressed: root.removeShelfItem(itemCard.itemId)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
