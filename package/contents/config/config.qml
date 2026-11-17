pragma ComponentBehavior: Bound

import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("General")
        icon: "preferences-desktop-theme-symbolic"
        source: "ConfigGeneral.qml"
    }
    ConfigCategory {
        name: i18n("Diagnostics")
        icon: "dialog-information-symbolic"
        source: "ConfigDiagnostics.qml"
    }
}
