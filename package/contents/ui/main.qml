pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore

PlasmoidItem {
    id: root

    readonly property bool onPanel: Plasmoid.formFactor === PlasmaCore.Types.Horizontal
                                 || Plasmoid.formFactor === PlasmaCore.Types.Vertical

    // KConfigPropertyMap dinamik anahtarlarını qmllint [missing-property] uyarısı üretmeden reaktif okur.
    readonly property var cfg: Plasmoid.configuration
    property int pendingPopupTab: -1

    // Plasma'nın yerel yarı saydam + KWin bulanık zemini (NoBackground bulanıklığı kapatır).
    Plasmoid.backgroundHints: PlasmaCore.Types.DefaultBackground

    // Güvenlik: uzak/tarayıcı kaynaklı parça adlarında HTML veya <img> işlenmesini engeller.
    toolTipTextFormat: Text.PlainText

    Theme {
        id: islandTheme
        name: String(root.cfg.theme || "kde")
        accentOverride: String(root.cfg.accentColor || "")
    }

    Backend {
        id: islandBackend
        expanded: root.expanded
        herdrEnabled: root.cfg.herdrEnabled === undefined ? true : Boolean(root.cfg.herdrEnabled)
        houraEnabled: root.cfg.houraEnabled === undefined ? true : Boolean(root.cfg.houraEnabled)
        weatherMode: String(root.cfg.weatherMode || "off")
        weatherCityConfig: String(root.cfg.weatherCity || "")
        weatherLatConfig: String(root.cfg.weatherLatitude || "")
        weatherLonConfig: String(root.cfg.weatherLongitude || "")
        claudeEnabled: root.cfg.quotaClaudeEnabled === undefined ? true : Boolean(root.cfg.quotaClaudeEnabled)
        agyEnabled: root.cfg.quotaAgyEnabled === undefined ? true : Boolean(root.cfg.quotaAgyEnabled)
        codexEnabled: root.cfg.quotaCodexEnabled === undefined ? true : Boolean(root.cfg.quotaCodexEnabled)
    }

    toolTipMainText: (islandBackend.mediaAvailable && islandBackend.trackTitle !== "")
        ? islandBackend.trackTitle
        : i18n("Quota Island")

    function withCacheNote(line: string, quota: var): string {
        const note = islandBackend.quotaNote(quota);
        return note !== "" ? (line + " · " + note) : line;
    }

    toolTipSubText: {
        const lines = [];
        if (islandBackend.mediaAvailable && islandBackend.trackArtist !== "") {
            lines.push(islandBackend.playbackStatus === "Playing"
                ? i18n("%1 (playing)", islandBackend.trackArtist)
                : (islandBackend.playbackStatus === "Paused"
                    ? i18n("%1 (paused)", islandBackend.trackArtist)
                    : i18n("%1 (stopped)", islandBackend.trackArtist)));
        }
        if (islandBackend.micInUse) {
            lines.push(i18n("Microphone in use: %1", islandBackend.micApps.join(", ")));
        }
        lines.push(islandBackend.muted
            ? i18n("Volume: muted (%1%)", islandBackend.volume)
            : i18n("Volume: %1%", islandBackend.volume));
        if (islandBackend.claudeShown && !islandBackend.claudeQuota.available) {
            lines.push(i18n("%1: %2", "Claude", islandBackend.quotaNote(islandBackend.claudeQuota)));
        }
        if (islandBackend.claudeShown && islandBackend.claudeQuota.available) {
            lines.push(root.withCacheNote(i18n("%1 5h: %2% · 7d: %3%", "Claude", Math.max(0, islandBackend.claude5hUsed), Math.max(0, islandBackend.claude7dUsed)), islandBackend.claudeQuota));
        }
        if (islandBackend.agyShown && !islandBackend.agyQuota.available) {
            lines.push(i18n("%1: %2", "AGY", islandBackend.quotaNote(islandBackend.agyQuota)));
        }
        if (islandBackend.agyShown && islandBackend.agyQuota.available) {
            const agy5h = Math.max(0, islandBackend.agyGemini5hUsed, islandBackend.agyClaude5hUsed);
            lines.push(root.withCacheNote(islandBackend.agy7dUsed >= 0
                ? i18n("%1 5h: %2% · 7d: %3%", "AGY", agy5h, islandBackend.agy7dUsed)
                : i18n("%1 5h: %2%", "AGY", agy5h), islandBackend.agyQuota));
        }
        if (islandBackend.codexShown && !islandBackend.codexQuota.available) {
            lines.push(i18n("%1: %2", "Codex", islandBackend.quotaNote(islandBackend.codexQuota)));
        }
        if (islandBackend.codexShown && islandBackend.codexQuota.available) {
            lines.push(root.withCacheNote(i18n("%1 5h: %2% · 7d: %3%", "Codex", Math.max(0, islandBackend.codex5hUsed), Math.max(0, islandBackend.codex7dUsed)), islandBackend.codexQuota));
        }
        return lines.join("\n");
    }

    onExpandedChanged: {
        if (!root.expanded) {
            root.pendingPopupTab = -1;
        }
    }

    preferredRepresentation: onPanel ? compactRepresentation : fullRepresentation

    compactRepresentation: CompactIsland {
        backend: islandBackend
        theme: islandTheme
        popupExpanded: root.expanded
        maxTrackWidth: Number(root.cfg.maxTrackWidth || 160)
        volumeStep: Number(root.cfg.volumeStep || 5)
        showVolumeBadge: root.cfg.showVolumeBadge === undefined ? true : Boolean(root.cfg.showVolumeBadge)
        showQuotaBadges: root.cfg.showQuotaBadges === undefined ? true : Boolean(root.cfg.showQuotaBadges)
        quotaWindowMode: String(root.cfg.quotaWindowMode || "both")
        onClicked: {
            root.expanded = !root.expanded;
        }
        onRequestExpand: {
            root.pendingPopupTab = -1;
            root.pendingPopupTab = 4;
            root.expanded = true;
        }
    }

    fullRepresentation: FullIsland {
        backend: islandBackend
        theme: islandTheme
        plasmoidItem: root
        volumeStep: Number(root.cfg.volumeStep || 5)
        requestedTab: root.pendingPopupTab

        Layout.minimumWidth: 560
        Layout.preferredWidth: 560
        Layout.maximumWidth: 560
        Layout.minimumHeight: 476
        Layout.preferredHeight: 476
        Layout.maximumHeight: 476
    }
}
