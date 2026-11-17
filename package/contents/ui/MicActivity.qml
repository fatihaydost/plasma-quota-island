pragma ComponentBehavior: Bound

import QtQuick
import org.kde.plasma.private.volume as PA

// Mikrofonu kullanan uygulamalar (olay tabanlı, yoklama yok). Plasma'nın özel modülü olduğundan
// Backend bunu Loader ile yükler; modül yoksa ya da API değişirse gösterge sessizce kapalı kalır.
// Sanal akışlar (Plasma'nın kendi seviye ölçerleri) ve duraklatılmış (corked) akışlar sayılmaz.
Item {
    id: root

    property var apps: []

    component StreamEntry: QtObject {
        required property var model

        readonly property bool active: !model.VirtualStream && !model.Corked
        readonly property string appName: {
            const props = model.Properties || {};
            const app = props["application.name"];
            if (app) {
                return String(app);
            }
            return model.Client && model.Client.name ? String(model.Client.name) : String(model.Name || "");
        }

        onActiveChanged: root.recompute()
        onAppNameChanged: root.recompute()
    }

    function recompute(): void {
        const names = [];
        for (let i = 0; i < streams.count; ++i) {
            const s = streams.objectAt(i) as StreamEntry;
            if (s && s.active && names.indexOf(s.appName) < 0) {
                names.push(s.appName);
            }
        }
        root.apps = names;
    }

    Instantiator {
        id: streams

        model: PA.SourceOutputModel {}

        delegate: StreamEntry {}

        onObjectAdded: root.recompute()
        onObjectRemoved: Qt.callLater(root.recompute)
    }
}
