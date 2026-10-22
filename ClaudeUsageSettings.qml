// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 nsella

import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "claudeDailyEstimateSpend"

    SelectionSetting {
        settingKey: "pillMetric"
        label: "Bar shows"
        description: "Which spend figure the bar pill displays"
        options: [
            {label: "Today", value: "today"},
            {label: "Last 5 hours", value: "window5h"},
            {label: "Last 7 days", value: "week"},
            {label: "This month", value: "month"}
        ]
        defaultValue: "today"
    }

    SelectionSetting {
        settingKey: "refreshSeconds"
        label: "Refresh interval"
        description: "How often to re-scan the Claude Code logs"
        options: [
            {label: "30 seconds", value: "30"},
            {label: "1 minute", value: "60"},
            {label: "5 minutes", value: "300"}
        ]
        defaultValue: "60"
    }
}
