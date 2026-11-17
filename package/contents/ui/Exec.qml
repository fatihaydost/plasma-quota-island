pragma ComponentBehavior: Bound

import QtQuick
import org.kde.plasma.plasma5support as P5Support

// KDE Plasma 6 P5Support.DataSource ("executable") sarmalayıcısı.
// plasmashell bellek sızıntısını önlemek için her onNewData çağrısında disconnectSource zorunludur.
// Ardışık aynı komutların connectSource tarafından düşürülmemesi için her çağrıya benzersiz '#seq-N' eki eklenir.
P5Support.DataSource {
    id: root

    engine: "executable"
    connectedSources: []

    property int _seq: 0
    property var _callbacks: ({})

    signal finished(string command, int exitCode, string stdout, string stderr)

    function run(cmd, callback) {
        const commandStr = cmd !== undefined && cmd !== null ? String(cmd) : "";
        if (commandStr === "") {
            return;
        }
        root._seq = (root._seq + 1) % 1000000000;
        const taggedSource = commandStr + " #seq-" + String(root._seq);

        const pending = root._callbacks;
        if (typeof callback === "function") {
            pending[taggedSource] = callback;
        }
        root.connectSource(taggedSource);
    }

    onNewData: function(sourceName, data) {
        const out = (data && data["stdout"] !== undefined) ? String(data["stdout"]) : "";
        const err = (data && data["stderr"] !== undefined) ? String(data["stderr"]) : "";
        const code = (data && data["exit code"] !== undefined) ? Number(data["exit code"]) : 0;

        // Zorunlu kaynak temizliği (sızıntı önlemi)
        root.disconnectSource(sourceName);

        const pending = root._callbacks;
        const cb = pending[sourceName];
        if (cb !== undefined) {
            delete pending[sourceName];
            if (typeof cb === "function") {
                cb(out, err, code, sourceName);
            }
        }

        const seqIdx = sourceName.lastIndexOf(" #seq-");
        const cleanCmd = seqIdx >= 0 ? sourceName.slice(0, seqIdx) : sourceName;
        root.finished(cleanCmd, code, out, err);
    }
}
