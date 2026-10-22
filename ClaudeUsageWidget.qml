// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 nsella

import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    readonly property string script: decodeURIComponent(Qt.resolvedUrl("usage.py").toString().replace("file://", ""))
    readonly property string pillMetric: pluginData.pillMetric || "today"
    readonly property int refreshSeconds: parseInt(pluginData.refreshSeconds || "60")
    // One per bar instance: Proc keeps only the latest callback per id, so a shared id starves the other bars
    readonly property string procId: "claudeDailyEstimateSpend.poll." + Math.random().toString(36).slice(2)
    readonly property var metricLabels: ({ "today": "Today", "window5h": "Last 5h", "week": "7 days", "month": "Month" })

    property var usage: null
    property string error: ""

    readonly property real pillCost: usage && usage[pillMetric] ? usage[pillMetric].cost : 0
    // Billing runs this much above the logs: Claude Code makes some calls it never writes to them
    // (Oct 2026 check: logs $96.22 vs console $102.67, +6.7%)
    readonly property real unloggedLow: 1.05
    readonly property real unloggedHigh: 1.07
    readonly property real maxDayCost: usage ? Math.max(0.01, ...usage.days.map(d => d.cost)) * unloggedHigh : 0.01

    function refresh() {
        Proc.runCommand(procId, ["python3", "-I", script], (out, code) => {
            if (code !== 0) {
                error = "usage.py exited with " + code;
                return;
            }
            try {
                usage = JSON.parse(out);
                error = "";
            } catch (e) {
                error = "bad output from usage.py";
            }
        }, 0, 60000);
    }

    function money(v) {
        if (v >= 1000)
            return "$" + (v / 1000).toFixed(1) + "k";
        return "$" + v.toFixed(v >= 100 ? 0 : 2);
    }

    function tokens(n) {
        if (n >= 1e9)
            return (n / 1e9).toFixed(1) + "B";
        if (n >= 1e6)
            return (n / 1e6).toFixed(1) + "M";
        if (n >= 1e3)
            return (n / 1e3).toFixed(0) + "k";
        return String(n);
    }

    function shortModel(m) {
        return m.replace(/^claude-/, "").replace(/-(\d+)-(\d+)$/, " $1.$2").replace(/-(\d+)$/, " $1");
    }

    Component.onDestruction: Proc.release(procId)

    Timer {
        interval: root.refreshSeconds * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                name: "payments"
                size: Theme.iconSize - 6
                color: root.error ? Theme.error : Theme.primary
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.usage ? root.money(root.pillCost) : "…"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                name: "payments"
                size: Theme.iconSize - 6
                color: root.error ? Theme.error : Theme.primary
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.usage ? "$" + Math.round(root.pillCost) : "…"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutWidth: 460
    popoutHeight: 820

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: "Claude Daily Spend Estimate"
            detailsText: root.error || "Claude Code on this machine · API list prices · faint band = likely billed (+5-7%)"
            showCloseButton: true

            Flickable {
                width: parent.width
                height: root.popoutHeight - popout.headerHeight - popout.detailsHeight - Theme.spacingL * 2
                contentHeight: body.height
                clip: true

                Column {
                    id: body
                    width: parent.width
                    spacing: Theme.spacingL
                    visible: !!root.usage

                    // Summary tiles
                    Row {
                        id: tiles
                        width: parent.width
                        spacing: Theme.spacingS

                        Repeater {
                            model: ["today", "window5h", "week", "month"]

                            StyledRect {
                                required property string modelData
                                readonly property var b: root.usage ? root.usage[modelData] : null

                                width: (tiles.width - tiles.spacing * 3) / 4
                                height: 88
                                radius: Theme.cornerRadius
                                color: modelData === root.pillMetric ? Theme.primaryContainer : Theme.surfaceContainerHigh

                                Column {
                                    anchors.centerIn: parent
                                    spacing: 2

                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: root.metricLabels[modelData]
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }

                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: b ? root.money(b.cost) : ""
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeLarge
                                        font.weight: Font.Bold
                                    }

                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: b ? root.tokens(b.tokens) + " tok" : ""
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                    }

                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: b && b.cost > 0 ? "≈ " + root.money(b.cost * root.unloggedLow) + "-" + root.money(b.cost * root.unloggedHigh) : ""
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall - 2
                                    }
                                }
                            }
                        }
                    }

                    // Last 14 days
                    Column {
                        width: parent.width
                        spacing: Theme.spacingS

                        StyledText {
                            text: "Last 14 days"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                        }

                        Row {
                            id: chart
                            width: parent.width
                            height: 108
                            spacing: 4

                            Repeater {
                                model: root.usage ? root.usage.days : []

                                Item {
                                    id: dayCol
                                    required property var modelData
                                    required property int index

                                    width: (chart.width - chart.spacing * 13) / 14
                                    height: chart.height

                                    readonly property real barArea: height - dayLabel.height - 2

                                    // Faint cap up to the likely billed price
                                    Rectangle {
                                        anchors.bottom: dayLabel.top
                                        anchors.bottomMargin: 2
                                        width: parent.width
                                        height: dayCol.barArea * dayCol.modelData.cost * root.unloggedHigh / root.maxDayCost
                                        radius: 3
                                        color: Theme.withAlpha(Theme.primary, 0.25)
                                    }

                                    Rectangle {
                                        anchors.bottom: dayLabel.top
                                        anchors.bottomMargin: 2
                                        width: parent.width
                                        height: Math.max(dayCol.modelData.cost > 0 ? 2 : 0, dayCol.barArea * dayCol.modelData.cost / root.maxDayCost)
                                        radius: 3
                                        color: dayCol.index === 13 ? Theme.primary : Theme.withAlpha(Theme.primary, 0.55)
                                    }

                                    MouseArea {
                                        id: barHover
                                        anchors.fill: parent
                                        hoverEnabled: true
                                    }

                                    // Second line keeps its height when empty so the bars don't jump on hover
                                    Column {
                                        id: dayLabel
                                        anchors.bottom: parent.bottom
                                        anchors.horizontalCenter: parent.horizontalCenter

                                        StyledText {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: barHover.containsMouse ? root.money(dayCol.modelData.cost) : dayCol.modelData.date.slice(8)
                                            color: barHover.containsMouse ? Theme.surfaceText : Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall - 2
                                        }

                                        StyledText {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: barHover.containsMouse ? "≈" + root.money(dayCol.modelData.cost * root.unloggedHigh) : " "
                                            color: Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall - 2
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Repeater {
                        model: [
                            { title: "Models this month", key: "models" },
                            { title: "Projects this month", key: "projects" }
                        ]

                        Column {
                            id: section
                            required property var modelData

                            width: body.width
                            spacing: Theme.spacingXS

                            StyledText {
                                text: section.modelData.title
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                bottomPadding: Theme.spacingXS
                            }

                            Repeater {
                                model: root.usage ? root.usage[section.modelData.key] : []

                                Item {
                                    id: line
                                    required property var modelData

                                    width: section.width
                                    height: 38

                                    Rectangle {
                                        anchors.left: parent.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        height: parent.height - 4
                                        radius: 4
                                        width: parent.width * (root.usage.month.cost > 0 ? line.modelData.cost / root.usage.month.cost : 0)
                                        color: Theme.withAlpha(Theme.primary, 0.15)
                                    }

                                    StyledText {
                                        anchors.left: parent.left
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.right: amount.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: section.modelData.key === "models" ? root.shortModel(line.modelData.name) : line.modelData.name
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeSmall
                                        elide: Text.ElideRight
                                    }

                                    Column {
                                        id: amount
                                        anchors.right: parent.right
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter

                                        StyledText {
                                            anchors.right: parent.right
                                            text: root.money(line.modelData.cost) + "  ·  " + root.tokens(line.modelData.tokens) + " tok  ·  " + line.modelData.requests + " req"
                                            color: Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall
                                        }

                                        StyledText {
                                            anchors.right: parent.right
                                            text: "≈ " + root.money(line.modelData.cost * root.unloggedLow) + "-" + root.money(line.modelData.cost * root.unloggedHigh) + " billed"
                                            color: Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall - 2
                                        }
                                    }
                                }
                            }
                        }
                    }

                    StyledText {
                        width: parent.width
                        visible: root.usage && root.usage.unpriced.length > 0
                        text: "No price for: " + (root.usage ? root.usage.unpriced.join(", ") : "") + " (counted as $0)"
                        color: Theme.warning
                        font.pixelSize: Theme.fontSizeSmall
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }
}
