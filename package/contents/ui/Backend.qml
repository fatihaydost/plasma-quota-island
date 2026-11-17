pragma ComponentBehavior: Bound

import QtQuick

// Quota Island birleşik durum yöneticisi:
// 1) island_ctl.py: MPRIS2 medya, PipeWire/PulseAudio ses, Claude/AGY/Codex abonelik kotaları (sağlayıcı başına aç/kapa)
// 2) live_ctl.py: Herdr canlı ajanlar, Houra odak, güç profili, pil/Bluetooth ve Dosya/Metin Rafı
// Üst üste binen (in-flight) sorguları _busyStatus, _busyQuotas ve _busyLive kilitleriyle önler.
Item {
    id: root

    visible: false
    implicitWidth: 0
    implicitHeight: 0
    width: 0
    height: 0

    // Popup açık/kapalı durumu (panel kapalıyken CPU yükünü düşürmek için 3000ms aralık kullanılır)
    property bool expanded: false

    // --- Ayarlar (main.qml'den) ---
    property bool herdrEnabled: true
    property bool houraEnabled: true
    property string weatherMode: "off"
    property string weatherCityConfig: ""
    property string weatherLatConfig: ""
    property string weatherLonConfig: ""

    // --- Entegrasyon görünürlüğü: araç yoksa veya ayarda kapalıysa kart/tetikleyici tamamen gizlenir ---
    readonly property bool herdrShown: root.herdrEnabled && root.herdrData.installed === true
    readonly property bool houraShown: root.houraEnabled && root.houraData.installed === true
    readonly property bool powerShown: root.powerData.available === true
    readonly property bool batteryShown: root.batteryData.available === true
    readonly property bool bluetoothShown: root.bluetoothData.available === true
    readonly property bool wifiControlShown: root.networkData.nmcli === true
    readonly property bool weatherEnabled: root.weatherMode === "manual" || root.weatherMode === "ip"

    onHerdrEnabledChanged: root.refreshLive()
    onHouraEnabledChanged: root.refreshLive()
    onWeatherModeChanged: root.refreshLive()
    onWeatherCityConfigChanged: root.refreshLive()
    onWeatherLatConfigChanged: root.refreshLive()
    onWeatherLonConfigChanged: root.refreshLive()

    function _weatherArgs() {
        const args = ["--weather", root.weatherEnabled ? root.weatherMode : "off"];
        if (root.weatherMode === "manual") {
            args.push("--city", root.weatherCityConfig.trim());
            if (root.weatherLatConfig.trim() !== "" && root.weatherLonConfig.trim() !== "") {
                args.push("--lat", root.weatherLatConfig.trim(), "--lon", root.weatherLonConfig.trim());
            }
        }
        return args;
    }

    function _liveStatusArgs() {
        const args = ["status"];
        if (!root.herdrEnabled) {
            args.push("--no-herdr");
        }
        if (!root.houraEnabled) {
            args.push("--no-houra");
        }
        return args.concat(root._weatherArgs());
    }

    // --- Medya Property'leri ---
    property bool mediaAvailable: false
    property string activePlayer: ""
    property string playerIdentity: ""
    property string playbackStatus: "Stopped"
    property string trackTitle: ""
    property string trackArtist: ""
    property string trackAlbum: ""
    property string artUrl: ""
    property real lengthSec: 0
    property real positionSec: 0
    property bool canPlay: false
    property bool canPause: false
    property bool canGoNext: false
    property bool canGoPrevious: false
    property bool canSeek: false
    property bool shuffle: false
    property string loopStatus: ""
    property bool canShuffle: false
    property bool canLoop: false
    property var players: []
    // İyimser medya düğmeleri: eylemden sonraki kısa sürede yolda olan eski yoklama durumu geri çevirmesin.
    property double _lastMediaActionMs: 0

    // --- Ses Property'leri ---
    property int volume: 0
    property bool muted: false
    property string sinkId: ""
    property string sinkName: ""
    property int sourceVolume: 100
    property bool sourceMuted: false
    property var sinks: []
    property var streams: []

    // --- Kota Property'leri ---
    property var claudeQuota: ({})
    property var agyQuota: ({})
    property var codexQuota: ({})
    // İlk kota yanıtı gelene dek Kotalar sekmesi gizlenmez (açılışta sekme atlamasın).
    property bool quotasLoaded: false

    // Kota ipucu/erişilebilirlik notu: kullanılamıyorsa neden, önbellekten geliyorsa "cached · N min ago".
    function quotaNote(quota: var): string {
        if (quota && quota.available === false && quota.configured !== false) {
            const r = String(quota.reason || "");
            return r === "auth_expired" ? i18n("Login expired") : r === "rate_limited" ? i18n("Rate limited")
                : r === "network" ? i18n("Offline") : i18n("Unavailable");
        }
        if (!quota || quota.source !== "cache") {
            return "";
        }
        const at = Number(quota.dataAt || 0);
        const mins = at > 0 ? Math.max(0, Math.round((Date.now() / 1000 - at) / 60)) : 0;
        return i18np("cached · %1 min ago", "cached · %1 min ago", mins);
    }
    // Ayarlardan gelir; kapalı sağlayıcı için ağ isteği yapılmaz.
    property bool claudeEnabled: true
    property bool agyEnabled: true
    property bool codexEnabled: true
    // Görünürlük: açık + kimlik bulunmuş (configured) sağlayıcı. İlk yanıttan önce hiçbiri görünmez.
    readonly property bool claudeShown: root._quotaShown(root.claudeQuota, root.claudeEnabled)
    readonly property bool agyShown: root._quotaShown(root.agyQuota, root.agyEnabled)
    readonly property bool codexShown: root._quotaShown(root.codexQuota, root.codexEnabled)
    readonly property bool anyQuotaShown: root.claudeShown || root.agyShown || root.codexShown
    property string quotasUpdatedAt: ""
    property bool quotasLoading: false

    // --- Canlı Etkinlikler & Raf Property'leri (live_ctl.py ortak kaynağı) ---
    property var liveData: ({})
    property string liveUpdatedAt: ""
    property var herdrData: ({})
    property int herdrWorkingCount: 0
    property int herdrBlockedCount: 0
    property int herdrDoneCount: 0
    property var herdrAgents: []
    property var houraData: ({})
    property var powerData: ({})
    property string powerProfile: "balanced"
    property var batteryData: ({})
    property var bluetoothData: ({})
    property var shelfItems: []
    property int shelfCount: 0

    // --- Sistem Yükü, Hava Durumu, Ağ & Modlar (live_ctl.py) ---
    property var sysloadData: ({})
    property int cpuPct: 0
    property int cpuTemp: -1
    property int ramPct: 0
    property real ramUsedGb: 0.0
    property real ramTotalGb: 0.0
    property int gpuPct: -1
    property int gpuTemp: -1
    property string gpuName: ""
    property int diskPct: 0
    property real diskUsedGb: 0.0
    property real diskTotalGb: 0.0

    property var weatherData: ({})
    property bool weatherAvailable: false
    property string weatherCity: ""
    property int weatherTemp: 0
    property int weatherFeelsLike: 0
    property int weatherHumidity: 0
    property int weatherWind: 0
    property int weatherPressure: 0
    property string weatherDesc: ""
    property string weatherIcon: "weather-few-clouds-symbolic"
    property var weatherDaily: []

    property var networkData: ({})
    property bool wiredOn: false
    property string wiredName: ""
    property bool wifiOn: false
    property string wifiSsid: ""
    property int wifiQuality: 0

    property var togglesData: ({})
    property bool dndActive: false
    property bool coffeeActive: false

    // --- Kısa Erişim Kota Property'leri (Panel ve Popup için) ---
    readonly property int claude5hUsed: root._quotaPct(root.claudeQuota, "fiveHour")
    readonly property int claude7dUsed: root._quotaPct(root.claudeQuota, "sevenDay")
    readonly property int claudeFable7dUsed: root._quotaPct(root.claudeQuota, "fableWeekly")
    readonly property int agyGemini5hUsed: root._quotaPct(root.agyQuota, "geminiPool")
    readonly property int agyClaude5hUsed: root._quotaPct(root.agyQuota, "claudePool")
    readonly property int agy7dUsed: root._quotaPct(root.agyQuota, "weekly")
    readonly property int codex5hUsed: root._quotaPct(root.codexQuota, "fiveHour")
    readonly property int codex7dUsed: root._quotaPct(root.codexQuota, "sevenDay")

    function _quotaShown(quota, enabled) {
        return Boolean(enabled && quota && (quota.configured === true || quota.available === true));
    }

    // Sağlayıcı kotasından tek pencerenin kullanılan yüzdesi; yoksa -1
    function _quotaPct(quota, key) {
        const bucket = (quota && quota.available) ? quota[key] : null;
        if (!bucket || bucket.usedPct === undefined || bucket.usedPct === null || Number(bucket.usedPct) < 0) {
            return -1;
        }
        return Math.round(Number(bucket.usedPct));
    }

    // --- In-flight Kilitleri & Zamanlayıcı Ayarları ---
    property bool _busyStatus: false
    property bool _busyQuotas: false
    property bool _busyLive: false
    property bool _pendingStatusRefresh: false
    property bool _pendingQuotasRefresh: false
    property bool _pendingQuotasForce: false
    property bool _pendingLiveRefresh: false
    property double _statusStartedAtMs: 0
    property double _quotasStartedAtMs: 0
    property double _liveStartedAtMs: 0

    property int statusIntervalMs: root.expanded
        ? ((root.mediaAvailable && root.playbackStatus === "Playing") ? 1500 : 2500)
        : ((root.mediaAvailable && root.playbackStatus === "Playing") ? 4000 : 6000)
    property int liveIntervalMs: root.expanded ? 3000 : 12000
    property int quotasIntervalMs: 180000

    readonly property string _scriptPath: {
        const resolved = Qt.resolvedUrl("../scripts/island_ctl.py").toString();
        if (resolved.startsWith("file://")) {
            return decodeURIComponent(resolved.slice(7));
        }
        return resolved;
    }

    readonly property string _liveScriptPath: {
        const resolved = Qt.resolvedUrl("../scripts/live_ctl.py").toString();
        if (resolved.startsWith("file://")) {
            return decodeURIComponent(resolved.slice(7));
        }
        return resolved;
    }

    onExpandedChanged: {
        if (root.expanded) {
            root.refreshStatus();
            root.refreshLive();
        }
    }

    function _shellQuote(arg) {
        const s = arg !== undefined && arg !== null ? String(arg).replace(/\0/g, "") : "";
        return "'" + s.replace(/'/g, "'\\''") + "'";
    }

    function _buildCmd(argsList) {
        let parts = ["/usr/bin/python3", root._shellQuote(root._scriptPath)];
        for (let i = 0; i < argsList.length; ++i) {
            parts.push(root._shellQuote(argsList[i]));
        }
        return parts.join(" ");
    }

    function _buildLiveCmd(argsList) {
        let parts = ["/usr/bin/python3", root._shellQuote(root._liveScriptPath)];
        for (let i = 0; i < argsList.length; ++i) {
            parts.push(root._shellQuote(argsList[i]));
        }
        return parts.join(" ");
    }

    function _runAction(argsList) {
        const cmd = root._buildCmd(argsList);
        runner.run(cmd, function() {
            root.refreshStatus();
        });
    }

    function _applyStatusPayload(payload) {
        if (!payload || typeof payload !== "object") {
            return;
        }
        const m = payload.media;
        if (m && typeof m === "object") {
            root.mediaAvailable = Boolean(m.available);
            root.activePlayer = m.activePlayer !== undefined ? String(m.activePlayer) : "";
            root.playerIdentity = m.identity !== undefined ? String(m.identity) : "";
            const settled = Date.now() - root._lastMediaActionMs >= 800;
            if (settled) {
                root.playbackStatus = m.playbackStatus !== undefined ? String(m.playbackStatus) : "Stopped";
                root.shuffle = Boolean(m.shuffle);
                root.loopStatus = m.loopStatus !== undefined ? String(m.loopStatus) : "";
            }
            root.canShuffle = Boolean(m.canShuffle);
            root.canLoop = Boolean(m.canLoop);
            root.trackTitle = m.title !== undefined ? String(m.title) : "";
            root.trackArtist = m.artist !== undefined ? String(m.artist) : "";
            root.trackAlbum = m.album !== undefined ? String(m.album) : "";
            root.artUrl = m.artUrl !== undefined ? String(m.artUrl) : "";
            root.lengthSec = m.lengthSec !== undefined && isFinite(Number(m.lengthSec)) ? Number(m.lengthSec) : 0;
            root.positionSec = m.positionSec !== undefined && isFinite(Number(m.positionSec)) ? Number(m.positionSec) : 0;
            root.canPlay = Boolean(m.canPlay);
            root.canPause = Boolean(m.canPause);
            root.canGoNext = Boolean(m.canGoNext);
            root.canGoPrevious = Boolean(m.canGoPrevious);
            root.canSeek = Boolean(m.canSeek);
            root.players = Array.isArray(m.players) ? m.players : [];
        }

        const a = payload.audio;
        if (a && typeof a === "object") {
            // Kullanıcının son ses hareketinden sonraki 500ms'de eski değer arayüzü geri sektirmesin.
            if (Date.now() - root._lastVolActionMs >= 500) {
                root.volume = a.volume !== undefined && isFinite(Number(a.volume))
                    ? Math.max(0, Math.min(150, Math.round(Number(a.volume))))
                    : 0;
                root.muted = Boolean(a.muted);
            }
            root.sinkId = a.sinkId !== undefined ? String(a.sinkId) : "";
            root.sinkName = a.sinkName !== undefined ? String(a.sinkName) : "";
            root.sourceVolume = a.sourceVolume !== undefined && isFinite(Number(a.sourceVolume))
                ? Math.max(0, Math.min(150, Math.round(Number(a.sourceVolume))))
                : 100;
            root.sourceMuted = Boolean(a.sourceMuted);
            root.sinks = Array.isArray(a.sinks) ? a.sinks : [];
            root.streams = Array.isArray(a.streams) ? a.streams : [];
        }
    }

    function _applyQuotasPayload(payload) {
        if (!payload || typeof payload !== "object") {
            return;
        }
        root.quotasLoaded = true;
        if (payload.updatedAt !== undefined) {
            root.quotasUpdatedAt = String(payload.updatedAt);
        }
        if (payload.claude && typeof payload.claude === "object") {
            root.claudeQuota = payload.claude;
        }
        if (payload.agy && typeof payload.agy === "object") {
            root.agyQuota = payload.agy;
        }
        if (payload.codex && typeof payload.codex === "object") {
            root.codexQuota = payload.codex;
        }
    }

    function _applyShelfResponse(stdout) {
        if (!stdout) {
            return false;
        }
        try {
            const parsed = JSON.parse(stdout);
            if (parsed && Array.isArray(parsed.items)) {
                root.shelfItems = parsed.items;
                root.shelfCount = parsed.count !== undefined
                    ? Math.max(0, Math.round(Number(parsed.count)))
                    : parsed.items.length;
                return true;
            }
            if (parsed && parsed.shelf && Array.isArray(parsed.shelf.items)) {
                root.shelfItems = parsed.shelf.items;
                root.shelfCount = parsed.shelf.count !== undefined
                    ? Math.max(0, Math.round(Number(parsed.shelf.count)))
                    : parsed.shelf.items.length;
                return true;
            }
        } catch (_err) {
            // Geçersiz JSON çıktısını yoksay
        }
        return false;
    }

    function _applyLivePayload(payload) {
        if (!payload || typeof payload !== "object") {
            return;
        }
        root.liveData = payload;
        if (payload.updatedAt !== undefined) {
            root.liveUpdatedAt = String(payload.updatedAt);
        }
        if (payload.herdr && typeof payload.herdr === "object") {
            root.herdrData = payload.herdr;
            root.herdrWorkingCount = payload.herdr.workingCount !== undefined && isFinite(Number(payload.herdr.workingCount))
                ? Math.max(0, Math.round(Number(payload.herdr.workingCount)))
                : 0;
            root.herdrBlockedCount = payload.herdr.blockedCount !== undefined && isFinite(Number(payload.herdr.blockedCount))
                ? Math.max(0, Math.round(Number(payload.herdr.blockedCount)))
                : 0;
            root.herdrDoneCount = payload.herdr.doneCount !== undefined && isFinite(Number(payload.herdr.doneCount))
                ? Math.max(0, Math.round(Number(payload.herdr.doneCount)))
                : 0;
            root.herdrAgents = Array.isArray(payload.herdr.agents) ? payload.herdr.agents : [];
        }
        if (payload.houra && typeof payload.houra === "object") {
            root.houraData = payload.houra;
        }
        if (payload.power && typeof payload.power === "object") {
            root.powerData = payload.power;
            const prof = payload.power.profile !== undefined ? String(payload.power.profile) : "";
            if (prof === "performance" || prof === "balanced" || prof === "power-saver") {
                root.powerProfile = prof;
            }
        }
        if (payload.battery && typeof payload.battery === "object") {
            root.batteryData = payload.battery;
        }
        if (payload.bluetooth && typeof payload.bluetooth === "object") {
            root.bluetoothData = payload.bluetooth;
        }
        if (payload.shelf && typeof payload.shelf === "object") {
            const items = Array.isArray(payload.shelf.items) ? payload.shelf.items : [];
            root.shelfItems = items;
            root.shelfCount = payload.shelf.count !== undefined && isFinite(Number(payload.shelf.count))
                ? Math.max(0, Math.round(Number(payload.shelf.count)))
                : items.length;
        }
        if (payload.sysload && typeof payload.sysload === "object") {
            const sl = payload.sysload;
            root.sysloadData = sl;
            root.cpuPct = sl.cpuPct !== undefined && isFinite(Number(sl.cpuPct)) ? Math.max(0, Math.min(100, Math.round(Number(sl.cpuPct)))) : 0;
            root.cpuTemp = sl.cpuTemp !== undefined && isFinite(Number(sl.cpuTemp)) ? Math.round(Number(sl.cpuTemp)) : -1;
            root.ramPct = sl.ramPct !== undefined && isFinite(Number(sl.ramPct)) ? Math.max(0, Math.min(100, Math.round(Number(sl.ramPct)))) : 0;
            root.ramUsedGb = sl.ramUsedGb !== undefined && isFinite(Number(sl.ramUsedGb)) ? Number(sl.ramUsedGb) : 0.0;
            root.ramTotalGb = sl.ramTotalGb !== undefined && isFinite(Number(sl.ramTotalGb)) ? Number(sl.ramTotalGb) : 0.0;
            root.gpuPct = sl.gpuPct !== undefined && isFinite(Number(sl.gpuPct)) ? Math.round(Number(sl.gpuPct)) : -1;
            root.gpuTemp = sl.gpuTemp !== undefined && isFinite(Number(sl.gpuTemp)) ? Math.round(Number(sl.gpuTemp)) : -1;
            root.gpuName = sl.gpuName !== undefined ? String(sl.gpuName) : "";
            root.diskPct = sl.diskPct !== undefined && isFinite(Number(sl.diskPct)) ? Math.max(0, Math.min(100, Math.round(Number(sl.diskPct)))) : 0;
            root.diskUsedGb = sl.diskUsedGb !== undefined && isFinite(Number(sl.diskUsedGb)) ? Number(sl.diskUsedGb) : 0.0;
            root.diskTotalGb = sl.diskTotalGb !== undefined && isFinite(Number(sl.diskTotalGb)) ? Number(sl.diskTotalGb) : 0.0;
        }
        if (payload.weather && typeof payload.weather === "object") {
            const w = payload.weather;
            root.weatherData = w;
            root.weatherAvailable = Boolean(w.available);
            root.weatherCity = w.city !== undefined ? String(w.city) : "";
            root.weatherTemp = w.temp !== undefined && isFinite(Number(w.temp)) ? Math.round(Number(w.temp)) : 0;
            root.weatherFeelsLike = w.feelsLike !== undefined && isFinite(Number(w.feelsLike)) ? Math.round(Number(w.feelsLike)) : 0;
            root.weatherHumidity = w.humidity !== undefined && isFinite(Number(w.humidity)) ? Math.max(0, Math.min(100, Math.round(Number(w.humidity)))) : 0;
            root.weatherWind = w.wind !== undefined && isFinite(Number(w.wind)) ? Math.max(0, Math.round(Number(w.wind))) : 0;
            root.weatherPressure = w.pressure !== undefined && isFinite(Number(w.pressure)) ? Math.round(Number(w.pressure)) : 0;
            root.weatherDesc = w.desc !== undefined ? String(w.desc) : "";
            root.weatherIcon = w.icon !== undefined ? String(w.icon) : "weather-few-clouds-symbolic";
            root.weatherDaily = Array.isArray(w.daily) ? w.daily : [];
        }
        if (payload.network && typeof payload.network === "object") {
            const n = payload.network;
            root.networkData = n;
            root.wiredOn = Boolean(n.wiredOn);
            root.wiredName = n.wiredName !== undefined ? String(n.wiredName) : "";
            root.wifiOn = Boolean(n.wifiOn);
            root.wifiSsid = n.wifiSsid !== undefined ? String(n.wifiSsid) : "";
            root.wifiQuality = n.wifiQuality !== undefined && isFinite(Number(n.wifiQuality)) ? Math.max(0, Math.min(100, Math.round(Number(n.wifiQuality)))) : 0;
        }
        if (payload.toggles && typeof payload.toggles === "object") {
            const t = payload.toggles;
            root.togglesData = t;
            root.dndActive = Boolean(t.dndActive);
            root.coffeeActive = Boolean(t.coffeeActive);
        }
    }

    // --- Sorgu Fonksiyonları ---
    function refreshStatus() {
        const nowMs = Date.now();
        if (root._busyStatus) {
            if (nowMs - root._statusStartedAtMs < 15000) {
                root._pendingStatusRefresh = true;
                return;
            }
            root._busyStatus = false;
        }

        root._busyStatus = true;
        root._pendingStatusRefresh = false;
        root._statusStartedAtMs = nowMs;

        const cmd = root._buildCmd(["status"]);
        runner.run(cmd, function(stdout, _stderr, exitCode) {
            root._busyStatus = false;
            if (exitCode === 0 && stdout) {
                try {
                    const parsed = JSON.parse(stdout);
                    root._applyStatusPayload(parsed);
                } catch (_err) {
                    // Geçersiz JSON çıktısını sessizce yoksay
                }
            }
            if (root._pendingStatusRefresh) {
                root._pendingStatusRefresh = false;
                Qt.callLater(root.refreshStatus);
            }
        });
    }

    function _enabledProviders() {
        const list = [];
        if (root.claudeEnabled) {
            list.push("claude");
        }
        if (root.agyEnabled) {
            list.push("agy");
        }
        if (root.codexEnabled) {
            list.push("codex");
        }
        return list;
    }

    onClaudeEnabledChanged: root.refreshQuotas(false)
    onAgyEnabledChanged: root.refreshQuotas(false)
    onCodexEnabledChanged: root.refreshQuotas(false)

    function refreshQuotas(force) {
        const wantForce = Boolean(force);
        const nowMs = Date.now();
        const providers = root._enabledProviders();
        if (providers.length === 0) {
            root.quotasLoaded = true; // hiç sağlayıcı açık değilse Kotalar sekmesi gizlenebilsin
            return;
        }
        if (root._busyQuotas) {
            if (nowMs - root._quotasStartedAtMs < 25000) {
                root._pendingQuotasRefresh = true;
                if (wantForce) {
                    root._pendingQuotasForce = true;
                }
                return;
            }
            root._busyQuotas = false;
        }

        root._busyQuotas = true;
        root.quotasLoading = true;
        root._pendingQuotasRefresh = false;
        root._pendingQuotasForce = false;
        root._quotasStartedAtMs = nowMs;

        const args = ["quotas", "--providers", providers.join(",")];
        if (wantForce) {
            args.push("--force");
        }
        const cmd = root._buildCmd(args);
        runner.run(cmd, function(stdout, _stderr, exitCode) {
            root._busyQuotas = false;
            root.quotasLoading = false;
            if (exitCode === 0 && stdout) {
                try {
                    const parsed = JSON.parse(stdout);
                    root._applyQuotasPayload(parsed);
                } catch (_err) {
                    // Geçersiz JSON çıktısını sessizce yoksay
                }
            }
            if (root._pendingQuotasRefresh) {
                const nextForce = root._pendingQuotasForce;
                root._pendingQuotasRefresh = false;
                root._pendingQuotasForce = false;
                Qt.callLater(function() {
                    root.refreshQuotas(nextForce);
                });
            }
        });
    }

    function refreshLive() {
        const nowMs = Date.now();
        if (root._busyLive) {
            if (nowMs - root._liveStartedAtMs < 12000) {
                root._pendingLiveRefresh = true;
                return;
            }
            root._busyLive = false;
        }

        root._busyLive = true;
        root._pendingLiveRefresh = false;
        root._liveStartedAtMs = nowMs;

        const cmd = root._buildLiveCmd(root._liveStatusArgs());
        runner.run(cmd, function(stdout, _stderr, exitCode) {
            root._busyLive = false;
            if (exitCode === 0 && stdout) {
                try {
                    const parsed = JSON.parse(stdout);
                    root._applyLivePayload(parsed);
                } catch (_err) {
                    // Geçersiz JSON çıktısını sessizce yoksay
                }
            }
            if (root._pendingLiveRefresh) {
                root._pendingLiveRefresh = false;
                Qt.callLater(root.refreshLive);
            }
        });
    }

    // --- Medya Eylem Fonksiyonları ---
    function playPause() {
        root._lastMediaActionMs = Date.now();
        if (root.playbackStatus === "Playing") {
            root.playbackStatus = "Paused";
        } else if (root.playbackStatus === "Paused") {
            root.playbackStatus = "Playing";
        }
        const args = ["media", "play-pause"];
        if (root.activePlayer !== "") {
            args.push(root.activePlayer);
        }
        root._runAction(args);
    }

    function toggleShuffle() {
        root._lastMediaActionMs = Date.now();
        root.shuffle = !root.shuffle;
        root._runAction(root.activePlayer !== "" ? ["media", "shuffle", root.activePlayer] : ["media", "shuffle"]);
    }

    function cycleLoop() {
        root._lastMediaActionMs = Date.now();
        const order = ["None", "Playlist", "Track"];
        const idx = order.indexOf(root.loopStatus);
        root.loopStatus = order[(idx + 1) % order.length];
        root._runAction(root.activePlayer !== "" ? ["media", "loop", root.activePlayer] : ["media", "loop"]);
    }

    function next() {
        const args = ["media", "next"];
        if (root.activePlayer !== "") {
            args.push(root.activePlayer);
        }
        root._runAction(args);
    }

    function previous() {
        const args = ["media", "prev"];
        if (root.activePlayer !== "") {
            args.push(root.activePlayer);
        }
        root._runAction(args);
    }

    function seek(seconds) {
        const target = isFinite(Number(seconds)) ? Math.max(0, Number(seconds)) : 0;
        root.positionSec = root.lengthSec > 0 ? Math.min(root.lengthSec, target) : target;
        const args = ["media", "seek", String(target)];
        if (root.activePlayer !== "") {
            args.push(root.activePlayer);
        }
        root._runAction(args);
    }

    function selectPlayer(busName) {
        const bus = busName !== undefined && busName !== null ? String(busName).trim() : "";
        if (bus === "" || !bus.startsWith("org.mpris.MediaPlayer2.")) {
            return;
        }
        root.activePlayer = bus;
        root._runAction(["media", "select-player", bus]);
    }

    // --- Ses Eylem Fonksiyonları ---
    // Ses anında (senkron) arayüze yansır; dış komut Python yerine doğrudan wpctl/pactl ikilisidir.
    // 25ms birleştirme hızlı tekerlek/kaydırıcıda süreç yığılmasını önler.
    property double _lastVolActionMs: 0

    function _markVolAction() {
        root._lastVolActionMs = Date.now();
        _volStatusSyncTimer.restart();
    }

    function _runShell(script) {
        runner.run("/bin/sh -c " + root._shellQuote(script), function() {});
    }

    property Timer _volCmdTimer: Timer {
        interval: 25
        onTriggered: {
            const v = String(Math.max(0, Math.min(150, Math.round(root.volume))));
            root._runShell("wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ " + v + "% || pactl set-sink-volume @DEFAULT_SINK@ " + v + "%");
        }
    }

    property Timer _volStatusSyncTimer: Timer {
        interval: 450
        onTriggered: root.refreshStatus()
    }

    function setVolume(pct) {
        const clamped = isFinite(Number(pct)) ? Math.max(0, Math.min(150, Math.round(Number(pct)))) : 0;
        root.volume = clamped;
        root._markVolAction();
        _volCmdTimer.start();
    }

    function changeVolume(delta) {
        const d = isFinite(Number(delta)) ? Math.round(Number(delta)) : 0;
        if (d === 0) {
            return;
        }
        root.setVolume(root.volume + d);
    }

    function toggleMute() {
        root.muted = !root.muted;
        root._markVolAction();
        root._runShell("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle || pactl set-sink-mute @DEFAULT_SINK@ toggle");
    }

    function toggleMic() {
        root.sourceMuted = !root.sourceMuted;
        root._runAction(["audio", "toggle-mic"]);
    }

    function setSink(sinkId) {
        const target = sinkId !== undefined && sinkId !== null ? String(sinkId).trim() : "";
        if (target === "" || target.startsWith("-")) {
            return;
        }
        root.sinkId = target;
        root._runAction(["audio", "set-sink", target]);
    }

    function setStreamVolume(streamId, pct) {
        const sid = streamId !== undefined && streamId !== null ? String(streamId).trim() : "";
        if (sid === "" || sid.startsWith("-")) {
            return;
        }
        const clamped = isFinite(Number(pct)) ? Math.max(0, Math.min(150, Math.round(Number(pct)))) : 100;
        root._runAction(["audio", "set-stream-volume", sid, String(clamped)]);
    }

    function toggleStreamMute(streamId) {
        const sid = streamId !== undefined && streamId !== null ? String(streamId).trim() : "";
        if (sid === "" || sid.startsWith("-")) {
            return;
        }
        root._runAction(["audio", "toggle-stream-mute", sid]);
    }

    // --- Canlı Etkinlikler & Raf Eylem Fonksiyonları (live_ctl.py) ---
    function focusAgent(id) {
        const cleanId = id !== undefined && id !== null ? String(id).trim() : "";
        if (!/^[A-Za-z0-9_.:@-]{1,64}$/.test(cleanId) || cleanId.startsWith("-")) {
            return;
        }
        const cmd = root._buildLiveCmd(["focus-agent", cleanId]);
        runner.run(cmd, function() {
            root.refreshLive();
        });
    }

    function setPowerProfile(prof) {
        const p = prof !== undefined && prof !== null ? String(prof).trim() : "";
        if (p !== "performance" && p !== "balanced" && p !== "power-saver") {
            return;
        }
        root.powerProfile = p;
        const cmd = root._buildLiveCmd(["set-power", p]);
        runner.run(cmd, function() {
            root.refreshLive();
        });
    }

    function shelfAdd(val) {
        if (val === undefined || val === null) {
            return;
        }
        let args = [];
        if (Array.isArray(val)) {
            let cleaned = [];
            for (let i = 0; i < val.length; ++i) {
                const item = String(val[i] || "").replace(/\0/g, "").trim();
                if (item !== "") {
                    cleaned.push(item);
                }
            }
            if (cleaned.length === 0) {
                return;
            }
            // "--": "--batch" gibi tire ile başlayan tek metin seçenek sanılmasın.
            args = cleaned.length === 1
                ? ["shelf-add", "--", cleaned[0]]
                : ["shelf-add", "--batch"].concat(cleaned);
        } else {
            const single = String(val).replace(/\0/g, "").trim();
            if (single === "") {
                return;
            }
            args = ["shelf-add", "--", single];
        }

        const cmd = root._buildLiveCmd(args);
        runner.run(cmd, function(stdout, _stderr, exitCode) {
            if (exitCode !== 0 || !root._applyShelfResponse(stdout)) {
                root.refreshLive();
            }
        });
    }

    function shelfRemove(id) {
        const sid = id !== undefined && id !== null ? String(id).trim() : "";
        if (!/^[A-Za-z0-9_-]{1,32}$/.test(sid) || sid.startsWith("-")) {
            return;
        }
        const cmd = root._buildLiveCmd(["shelf-remove", sid]);
        runner.run(cmd, function(stdout, _stderr, exitCode) {
            if (exitCode !== 0 || !root._applyShelfResponse(stdout)) {
                root.refreshLive();
            }
        });
    }

    function shelfClear() {
        root.shelfItems = [];
        root.shelfCount = 0;
        const cmd = root._buildLiveCmd(["shelf-clear"]);
        runner.run(cmd, function(stdout, _stderr, exitCode) {
            if (exitCode !== 0 || !root._applyShelfResponse(stdout)) {
                root.refreshLive();
            }
        });
    }

    function shelfOpen(id) {
        const sid = id !== undefined && id !== null ? String(id).trim() : "";
        if (!/^[A-Za-z0-9_-]{1,32}$/.test(sid) || sid.startsWith("-")) {
            return;
        }
        const cmd = root._buildLiveCmd(["shelf-open", sid]);
        runner.run(cmd, function() {});
    }

    function shelfCopy(id) {
        const sid = id !== undefined && id !== null ? String(id).trim() : "";
        if (!/^[A-Za-z0-9_-]{1,32}$/.test(sid) || sid.startsWith("-")) {
            return;
        }
        const cmd = root._buildLiveCmd(["shelf-copy", sid]);
        runner.run(cmd, function() {});
    }

    function toggleWifi() {
        const nextOn = !root.wifiOn;
        root.wifiOn = nextOn;
        if (!nextOn) {
            root.wifiSsid = "";
            root.wifiQuality = 0;
        }
        const cmd = root._buildLiveCmd(["wifi-toggle", nextOn ? "on" : "off"]);
        runner.run(cmd, function() {
            root.refreshLive();
        });
    }

    function toggleBluetooth() {
        const cmd = root._buildLiveCmd(["bt-toggle"]);
        runner.run(cmd, function() {
            root.refreshLive();
        });
    }

    function toggleDnd() {
        const nextOn = !root.dndActive;
        root.dndActive = nextOn;
        const cmd = root._buildLiveCmd(["dnd-toggle", nextOn ? "on" : "off"]);
        runner.run(cmd, function() {
            root.refreshLive();
        });
    }

    function toggleCoffee() {
        const nextOn = !root.coffeeActive;
        root.coffeeActive = nextOn;
        const cmd = root._buildLiveCmd(["coffee-toggle", nextOn ? "on" : "off"]);
        runner.run(cmd, function() {
            root.refreshLive();
        });
    }

    function refreshWeather() {
        if (!root.weatherEnabled) {
            return;
        }
        const cmd = root._buildLiveCmd(["weather-refresh"].concat(root._weatherArgs()));
        runner.run(cmd, function() {
            root.refreshLive();
        });
    }

    function runPowerAction(action) {
        const act = action !== undefined && action !== null ? String(action).trim().toLowerCase() : "";
        if (act !== "sleep" && act !== "lock" && act !== "logout" && act !== "reboot" && act !== "poweroff") {
            return;
        }
        const cmd = root._buildLiveCmd(["power-action", act]);
        runner.run(cmd, function() {});
    }

    // Mikrofon kullanım göstergesi: özel Plasma modülü; yüklenemezse micApps boş kalır.
    Loader {
        id: micLoader
        source: "MicActivity.qml"
    }
    readonly property var micApps: (micLoader.status === Loader.Ready && micLoader.item) ? micLoader.item.apps : []
    readonly property bool micInUse: root.micApps.length > 0

    Exec {
        id: runner
    }

    Timer {
        id: positionTickTimer
        interval: 1000
        running: root.expanded && root.mediaAvailable && root.playbackStatus === "Playing"
        repeat: true
        onTriggered: {
            if (root.lengthSec > 0) {
                root.positionSec = Math.min(root.lengthSec, root.positionSec + 1.0);
            } else {
                root.positionSec = root.positionSec + 1.0;
            }
        }
    }

    Timer {
        id: statusTimer
        interval: root.statusIntervalMs
        running: true
        repeat: true
        onTriggered: root.refreshStatus()
    }

    Timer {
        id: liveTimer
        interval: root.liveIntervalMs
        running: true
        repeat: true
        onTriggered: root.refreshLive()
    }

    Timer {
        id: quotasTimer
        interval: root.quotasIntervalMs
        running: true
        repeat: true
        onTriggered: root.refreshQuotas(false)
    }

    Component.onCompleted: {
        root.refreshStatus();
        root.refreshLive();
        root.refreshQuotas(false);
    }
}
