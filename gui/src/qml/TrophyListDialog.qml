import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

Dialog {
    id: dialog
    
    property string currentTitleId: ""
    property string currentNpCommunicationId: ""
    property var trophyData: null
    property var allTrophyGroups: []
    property int currentGroupIndex: 0
    property string sortMode: "default"  // default, earned, type
    property string filterMode: "all"  // all, earned, not_earned
    property bool isRefreshing: false
    
    title: trophyData ? trophyData.trophyTitleName || qsTr("Trophies") : qsTr("Loading Trophies...")
    modal: true
    width: 900
    height: 700
    
    function showTrophies(titleId, npCommunicationId) {
        currentTitleId = titleId
        currentNpCommunicationId = npCommunicationId
        trophyData = null
        allTrophyGroups = []
        currentGroupIndex = 0
        sortMode = "default"
        filterMode = "all"
        isRefreshing = false
        open()
        
        // Request trophy data from games backend (with cache)
        ChiakiGames.fetchTrophyData(npCommunicationId, false)
    }
    
    function refreshTrophies() {
        isRefreshing = true
        trophyData = null
        allTrophyGroups = []
        cachedFilteredTrophies = []
        
        // Force refresh (bypass cache)
        ChiakiGames.fetchTrophyData(currentNpCommunicationId, true)
    }
    
    property var cachedFilteredTrophies: []
    
    function getCurrentTrophies() {
        if (!allTrophyGroups[currentGroupIndex] || !allTrophyGroups[currentGroupIndex].trophies)
            return []
        
        let trophies = allTrophyGroups[currentGroupIndex].trophies.slice()  // Always copy
        
        // Filter
        if (filterMode === "earned") {
            trophies = trophies.filter(t => t.earned === true)
        } else if (filterMode === "not_earned") {
            trophies = trophies.filter(t => !t.earned)
        }
        
        // Sort
        if (sortMode === "earned") {
            trophies.sort((a, b) => {
                if (a.earned && !b.earned) return -1
                if (!a.earned && b.earned) return 1
                return 0
            })
        } else if (sortMode === "type") {
            // Platinum first, then Gold, Silver, Bronze
            let typeOrder = {"platinum": 0, "gold": 1, "silver": 2, "bronze": 3}
            trophies.sort((a, b) => {
                let aType = (a.trophyType || "").toLowerCase()
                let bType = (b.trophyType || "").toLowerCase()
                let aOrder = typeOrder.hasOwnProperty(aType) ? typeOrder[aType] : 99
                let bOrder = typeOrder.hasOwnProperty(bType) ? typeOrder[bType] : 99
                return aOrder - bOrder
            })
        }
        
        return trophies
    }
    
    // Trigger trophy list refresh when sort/filter changes
    onSortModeChanged: {
        Qt.callLater(() => {
            cachedFilteredTrophies = getCurrentTrophies()
            trophyList.model = null  // Force refresh
            trophyList.model = cachedFilteredTrophies
            if (trophyList.count > 0) {
                trophyList.currentIndex = 0
            }
        })
    }
    
    onFilterModeChanged: {
        Qt.callLater(() => {
            cachedFilteredTrophies = getCurrentTrophies()
            trophyList.model = null  // Force refresh
            trophyList.model = cachedFilteredTrophies
            if (trophyList.count > 0) {
                trophyList.currentIndex = 0
            }
        })
    }
    
    onCurrentGroupIndexChanged: {
        Qt.callLater(() => {
            cachedFilteredTrophies = getCurrentTrophies()
            trophyList.model = null  // Force refresh
            trophyList.model = cachedFilteredTrophies
            if (trophyList.count > 0) {
                trophyList.currentIndex = 0
            }
        })
    }
    
    Connections {
        target: ChiakiGames
        
        function onTrophyDataReceived(npTitleId, data) {
            if (npTitleId === currentNpCommunicationId) {
                try {
                    let parsed = JSON.parse(data)
                    trophyData = parsed
                    
                    // Group trophies by trophy group
                    if (parsed.trophies && Array.isArray(parsed.trophies)) {
                        let groups = {}
                        
                        // Group trophies
                        for (let trophy of parsed.trophies) {
                            let groupId = trophy.trophyGroupId || "default"
                            if (!groups[groupId]) {
                                groups[groupId] = {
                                    groupId: groupId,
                                    groupName: groupId === "default" ? qsTr("Base Game") : qsTr("DLC %1").arg(groupId),
                                    trophies: [],
                                    earnedCount: 0,
                                    totalCount: 0
                                }
                            }
                            groups[groupId].trophies.push(trophy)
                            groups[groupId].totalCount++
                            if (trophy.earned === true) {
                                groups[groupId].earnedCount++
                            }
                        }
                        
                        // Convert to array
                        allTrophyGroups = Object.values(groups)
                        console.log("Trophy groups:", allTrophyGroups.length)
                        
                        // Initial cache
                        cachedFilteredTrophies = getCurrentTrophies()
                    }
                } catch (e) {
                    console.error("Failed to parse trophy data:", e)
                } finally {
                    isRefreshing = false
                }
            }
        }
    }
    
    onOpened: {
        Qt.callLater(() => {
            if (trophyList.count > 0) {
                trophyList.currentIndex = 0
                trophyList.forceActiveFocus()
            } else {
                refreshButton.forceActiveFocus()
            }
        })
    }
    
    contentItem: ColumnLayout {
        spacing: 0
        
        // Trophy Summary Header
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 100
            color: Qt.rgba(0, 212/255, 255/255, 0.05)
            
            // Refresh button in top-right corner
            Button {
                id: refreshButton
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: 12
                anchors.rightMargin: 12
                text: isRefreshing ? qsTr("Refreshing...") : qsTr("🔄 Refresh")
                font.pixelSize: 12
                enabled: !isRefreshing
                focusPolicy: Qt.StrongFocus
                ToolTip.text: qsTr("Refresh trophy data from PSN (bypasses 24h cache)")
                ToolTip.visible: hovered || activeFocus
                
                KeyNavigation.down: sortDefaultButton
                
                background: Rectangle {
            radius: 4
                    color: parent.activeFocus ? Qt.rgba(76/255, 175/255, 80/255, 0.4) : Qt.rgba(76/255, 175/255, 80/255, 0.2)
                    border.width: parent.activeFocus ? 2 : 1
                    border.color: parent.activeFocus ? "#4CAF50" : Qt.rgba(76/255, 175/255, 80/255, 0.5)
                }
                
                contentItem: Text {
                    text: parent.text
                    font: parent.font
                    color: Qt.rgba(76/255, 175/255, 80/255, 1)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                
                onClicked: refreshTrophies()
                
                BusyIndicator {
                    anchors.centerIn: parent
                    width: 16
                    height: 16
                    running: isRefreshing
                    visible: isRefreshing
                }
            }
            
            RowLayout {
                anchors.fill: parent
                anchors.margins: 20
                anchors.rightMargin: 140  // Make room for refresh button
                spacing: 32
                
                // Platinum
                ColumnLayout {
                    spacing: 4
                    Label {
                        text: trophyData && trophyData.earnedTrophies ? trophyData.earnedTrophies.platinum || 0 : 0
                        font.pixelSize: 28
                        font.bold: true
                        color: "#E5E5E5"
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Label {
                        text: qsTr("Platinum")
                        font.pixelSize: 11
                        opacity: 0.7
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
                
                // Gold
                ColumnLayout {
                    spacing: 4
                    Label {
                        text: trophyData && trophyData.earnedTrophies ? trophyData.earnedTrophies.gold || 0 : 0
                        font.pixelSize: 28
                        font.bold: true
                        color: "#FFD700"
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Label {
                        text: qsTr("Gold")
                        font.pixelSize: 11
                        opacity: 0.7
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
                
                // Silver
                ColumnLayout {
                    spacing: 4
                    Label {
                        text: trophyData && trophyData.earnedTrophies ? trophyData.earnedTrophies.silver || 0 : 0
                        font.pixelSize: 28
                        font.bold: true
                        color: "#C0C0C0"
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Label {
                        text: qsTr("Silver")
                        font.pixelSize: 11
                        opacity: 0.7
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
                
                // Bronze
                ColumnLayout {
                    spacing: 4
                    Label {
                        text: trophyData && trophyData.earnedTrophies ? trophyData.earnedTrophies.bronze || 0 : 0
                        font.pixelSize: 28
                        font.bold: true
                        color: "#CD7F32"
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Label {
                        text: qsTr("Bronze")
                        font.pixelSize: 11
                        opacity: 0.7
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
                
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.fillHeight: true
                    color: Qt.rgba(255, 255, 255, 0.1)
                }
                
                // Progress
                ColumnLayout {
                    spacing: 4
                    Label {
                        text: trophyData && trophyData.progress ? trophyData.progress + "%" : "0%"
                        font.pixelSize: 36
                        font.bold: true
                        color: Material.accent
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Label {
                        text: qsTr("Complete")
                        font.pixelSize: 11
                        opacity: 0.7
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
                
                Item { Layout.fillWidth: true }
            }
        }
        
        // Trophy Groups Tabs
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 50
            color: Qt.rgba(0, 0, 0, 0.2)
            visible: allTrophyGroups.length > 1
            
            ScrollView {
                anchors.fill: parent
                contentWidth: groupTabs.implicitWidth
                ScrollBar.vertical.policy: ScrollBar.AlwaysOff
                
                Row {
                    id: groupTabs
                    height: parent.height
                    spacing: 0
                    
                    Repeater {
                        model: allTrophyGroups
                        
                        Button {
                            height: parent.height
                            flat: true
                            text: modelData.groupName + " (" + modelData.earnedCount + "/" + modelData.totalCount + ")"
                            font.pixelSize: 13
                            font.weight: currentGroupIndex === index ? Font.Bold : Font.Normal
                            
                            background: Rectangle {
                                color: currentGroupIndex === index ? Qt.rgba(0, 212/255, 255/255, 0.2) : "transparent"
                                Rectangle {
                                    anchors.bottom: parent.bottom
                                    width: parent.width
                                    height: 3
                                    color: Material.accent
                                    visible: currentGroupIndex === index
                                }
                            }
                            
                            onClicked: {
                                currentGroupIndex = index
                                if (trophyList.count > 0) {
                                    trophyList.currentIndex = 0
                                    trophyList.forceActiveFocus()
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Filter and Sort Controls
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 60
            color: Qt.rgba(0, 0, 0, 0.2)
            
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                spacing: 16
                
                // Sort Section
                RowLayout {
                    spacing: 8
                    
                    Label {
                        text: qsTr("SORT BY")
                        font.pixelSize: 11
                        font.weight: Font.Bold
                        font.letterSpacing: 1
                        color: Material.accent
                    }
                    
                    Button {
                        id: sortDefaultButton
                        text: qsTr("Default")
                        flat: true
                        font.pixelSize: 12
                        font.weight: sortMode === "default" ? Font.Bold : Font.Normal
                        focusPolicy: Qt.StrongFocus
                        
                        KeyNavigation.up: refreshButton
                        KeyNavigation.right: sortEarnedButton
                        KeyNavigation.down: trophyList
                        
                        background: Rectangle {
                            radius: 4
                            color: sortMode === "default" ? Material.accent : (parent.activeFocus ? Qt.rgba(255, 255, 255, 0.15) : Qt.rgba(255, 255, 255, 0.05))
                            border.width: parent.activeFocus ? 2 : 1
                            border.color: parent.activeFocus ? "#ffffff" : (sortMode === "default" ? Material.accent : Qt.rgba(255, 255, 255, 0.1))
                        }
                        
                        contentItem: Text {
                            text: parent.text
                            font: parent.font
                            color: sortMode === "default" ? "#000000" : Qt.rgba(255, 255, 255, 0.8)
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        
                        onClicked: sortMode = "default"
                    }
                    
                    Button {
                        id: sortEarnedButton
                        text: qsTr("Earned First")
                        flat: true
                        font.pixelSize: 12
                        font.weight: sortMode === "earned" ? Font.Bold : Font.Normal
                        focusPolicy: Qt.StrongFocus
                        
                        KeyNavigation.left: sortDefaultButton
                        KeyNavigation.right: sortTypeButton
                        KeyNavigation.down: trophyList
                        
                        background: Rectangle {
                            radius: 4
                            color: sortMode === "earned" ? Material.accent : (parent.activeFocus ? Qt.rgba(255, 255, 255, 0.15) : Qt.rgba(255, 255, 255, 0.05))
                            border.width: parent.activeFocus ? 2 : 1
                            border.color: parent.activeFocus ? "#ffffff" : (sortMode === "earned" ? Material.accent : Qt.rgba(255, 255, 255, 0.1))
                        }
                        
                        contentItem: Text {
                            text: parent.text
                            font: parent.font
                            color: sortMode === "earned" ? "#000000" : Qt.rgba(255, 255, 255, 0.8)
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        
                        onClicked: sortMode = "earned"
                    }
                    
                    Button {
                        id: sortTypeButton
                        text: qsTr("By Type")
                        flat: true
                        font.pixelSize: 12
                        font.weight: sortMode === "type" ? Font.Bold : Font.Normal
                        focusPolicy: Qt.StrongFocus
                        ToolTip.text: qsTr("Sort by trophy type (Platinum, Gold, Silver, Bronze)")
                        ToolTip.visible: hovered || activeFocus
                        
                        KeyNavigation.left: sortEarnedButton
                        KeyNavigation.right: filterAllButton
                        KeyNavigation.down: trophyList
                        
                        background: Rectangle {
                            radius: 4
                            color: sortMode === "type" ? Material.accent : (parent.activeFocus ? Qt.rgba(255, 255, 255, 0.15) : Qt.rgba(255, 255, 255, 0.05))
                            border.width: parent.activeFocus ? 2 : 1
                            border.color: parent.activeFocus ? "#ffffff" : (sortMode === "type" ? Material.accent : Qt.rgba(255, 255, 255, 0.1))
                        }
                        
                        contentItem: Text {
                            text: parent.text
                            font: parent.font
                            color: sortMode === "type" ? "#000000" : Qt.rgba(255, 255, 255, 0.8)
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        
                        onClicked: sortMode = "type"
                    }
                }
                
                Rectangle {
                    Layout.preferredWidth: 2
                    Layout.fillHeight: true
                    Layout.topMargin: 12
                    Layout.bottomMargin: 12
                    color: Qt.rgba(0, 212/255, 255/255, 0.3)
                }
                
                // Filter Section
                RowLayout {
                    spacing: 8
                    
                    Label {
                        text: qsTr("SHOW")
                        font.pixelSize: 11
                        font.weight: Font.Bold
                        font.letterSpacing: 1
                        color: "#9C27B0"
                    }
                    
                    Button {
                        id: filterAllButton
                        text: qsTr("All")
                        flat: true
                        font.pixelSize: 12
                        font.weight: filterMode === "all" ? Font.Bold : Font.Normal
                        focusPolicy: Qt.StrongFocus
                        
                        KeyNavigation.left: sortTypeButton
                        KeyNavigation.right: filterEarnedButton
                        KeyNavigation.down: trophyList
                        
                        background: Rectangle {
                            radius: 4
                            color: filterMode === "all" ? "#9C27B0" : (parent.activeFocus ? Qt.rgba(156/255, 39/255, 176/255, 0.3) : Qt.rgba(156/255, 39/255, 176/255, 0.1))
                            border.width: parent.activeFocus ? 2 : 1
                            border.color: parent.activeFocus ? "#ffffff" : (filterMode === "all" ? "#9C27B0" : Qt.rgba(156/255, 39/255, 176/255, 0.3))
                        }
                        
                        contentItem: Text {
                            text: parent.text
                            font: parent.font
                            color: filterMode === "all" ? "#ffffff" : Qt.rgba(255, 255, 255, 0.8)
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        
                        onClicked: filterMode = "all"
                    }
                    
                    Button {
                        id: filterEarnedButton
                        text: qsTr("✓ Earned")
                        flat: true
                        font.pixelSize: 12
                        font.weight: filterMode === "earned" ? Font.Bold : Font.Normal
                        focusPolicy: Qt.StrongFocus
                        
                        KeyNavigation.left: filterAllButton
                        KeyNavigation.right: filterNotEarnedButton
                        KeyNavigation.down: trophyList
                        
                        background: Rectangle {
                            radius: 4
                            color: filterMode === "earned" ? "#9C27B0" : (parent.activeFocus ? Qt.rgba(156/255, 39/255, 176/255, 0.3) : Qt.rgba(156/255, 39/255, 176/255, 0.1))
                            border.width: parent.activeFocus ? 2 : 1
                            border.color: parent.activeFocus ? "#ffffff" : (filterMode === "earned" ? "#9C27B0" : Qt.rgba(156/255, 39/255, 176/255, 0.3))
                        }
                        
                        contentItem: Text {
                            text: parent.text
                            font: parent.font
                            color: filterMode === "earned" ? "#ffffff" : Qt.rgba(255, 255, 255, 0.8)
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        
                        onClicked: filterMode = "earned"
                    }
                    
                    Button {
                        id: filterNotEarnedButton
                        text: qsTr("Not Earned")
                        flat: true
                        font.pixelSize: 12
                        font.weight: filterMode === "not_earned" ? Font.Bold : Font.Normal
                        focusPolicy: Qt.StrongFocus
                        
                        KeyNavigation.left: filterEarnedButton
                        KeyNavigation.down: trophyList
                        
                        background: Rectangle {
                            radius: 4
                            color: filterMode === "not_earned" ? "#9C27B0" : (parent.activeFocus ? Qt.rgba(156/255, 39/255, 176/255, 0.3) : Qt.rgba(156/255, 39/255, 176/255, 0.1))
                            border.width: parent.activeFocus ? 2 : 1
                            border.color: parent.activeFocus ? "#ffffff" : (filterMode === "not_earned" ? "#9C27B0" : Qt.rgba(156/255, 39/255, 176/255, 0.3))
                        }
                        
                        contentItem: Text {
                            text: parent.text
                            font: parent.font
                            color: filterMode === "not_earned" ? "#ffffff" : Qt.rgba(255, 255, 255, 0.8)
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        
                        onClicked: filterMode = "not_earned"
                    }
                }
                
                Item { Layout.fillWidth: true }
                
                Label {
                    text: cachedFilteredTrophies.length + qsTr(" trophies")
                    font.pixelSize: 13
                    font.weight: Font.Medium
                    color: Material.accent
                }
            }
        }
        
        // Trophy List
        ListView {
            id: trophyList
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0
            clip: true
            focus: true
            keyNavigationEnabled: true
            keyNavigationWraps: false
            
            model: cachedFilteredTrophies
            
            highlight: Rectangle {
                color: Qt.rgba(0, 212/255, 255/255, 0.15)
                border.color: Material.accent
                border.width: 2
            }
            highlightMoveDuration: 150
            
            delegate: ItemDelegate {
                required property int index
                required property var modelData
                width: trophyList.width
                height: 90
                
                background: Rectangle {
                    color: index % 2 === 0 ? Qt.rgba(0, 0, 0, 0.1) : Qt.rgba(0, 0, 0, 0.05)
                    opacity: modelData.earned === true ? 1.0 : 0.6
                }
                
                contentItem: RowLayout {
                    spacing: 16
                    
                    // Trophy Icon
                    Item {
                        Layout.preferredWidth: 64
                        Layout.preferredHeight: 64
                        Layout.alignment: Qt.AlignVCenter
                        
                        Image {
                            anchors.fill: parent
                                source: modelData.trophyIconUrl || ""
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                            opacity: modelData.earned === true ? 1.0 : 0.4
                        }
                        
                        // Earned checkmark overlay
                        Rectangle {
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            width: 24
                            height: 24
                            radius: 12
                            color: "#4CAF50"
                            visible: !!(modelData.earned)
                            
                            Label {
                                anchors.centerIn: parent
                                text: "✓"
                                font.pixelSize: 16
                                font.bold: true
                                color: "white"
                            }
                        }
                            }
                            
                            // Trophy Info
                            ColumnLayout {
                                Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 6
                        
                        // Trophy Name and Type Badge
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                                
                                Label {
                                Layout.fillWidth: true
                                    text: modelData.trophyName || ""
                                font.pixelSize: 15
                                    font.bold: true
                                elide: Text.ElideRight
                            }
                            
                            // Trophy Type Badge
                            Rectangle {
                                Layout.preferredWidth: 68
                                Layout.preferredHeight: 22
                                radius: 3
                                color: {
                                    switch(modelData.trophyType) {
                                        case "platinum": return Qt.rgba(229/255, 229/255, 229/255, 0.25)
                                        case "gold": return Qt.rgba(1, 215/255, 0, 0.25)
                                        case "silver": return Qt.rgba(192/255, 192/255, 192/255, 0.25)
                                        case "bronze": return Qt.rgba(205/255, 127/255, 50/255, 0.25)
                                        default: return Qt.rgba(255, 255, 255, 0.1)
                                    }
                                }
                                
                                Label {
                                    anchors.centerIn: parent
                                    text: modelData.trophyType || ""
                                    font.pixelSize: 10
                                    font.weight: Font.DemiBold
                                    font.capitalization: Font.AllUppercase
                                    color: {
                                        switch(modelData.trophyType) {
                                            case "platinum": return "#E5E5E5"
                                            case "gold": return "#FFD700"
                                            case "silver": return "#C0C0C0"
                                            case "bronze": return "#CD7F32"
                                            default: return "white"
                                        }
                                    }
                                }
                            }
                        }
                        
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            
                            Label {
                                Layout.fillWidth: true
                                text: modelData.trophyDetail || ""
                                font.pixelSize: 12
                                opacity: 0.7
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }
                            
                            // Hidden trophy badge (integrated inline)
                            Rectangle {
                                Layout.preferredWidth: 50
                                Layout.preferredHeight: 18
                                radius: 2
                                color: Qt.rgba(255, 152/255, 0, 0.2)
                                border.width: 1
                                border.color: Qt.rgba(255, 152/255, 0, 0.5)
                                visible: !!(modelData.trophyHidden && !modelData.earned)
                                
                                Label {
                                    anchors.centerIn: parent
                                    text: qsTr("🔒 Hidden")
                                    font.pixelSize: 8
                                    font.weight: Font.Medium
                                    color: Qt.rgba(255, 152/255, 0, 1)
                                }
                            }
                        }
                    }
                }
                
                onClicked: {
                    trophyList.currentIndex = index
                }
            }
            
            // Empty state
            Label {
                anchors.centerIn: parent
                text: {
                    if (!trophyData) return qsTr("Loading trophies...")
                    if (allTrophyGroups.length === 0) return qsTr("No trophies available")
                    if (filterMode === "earned") return qsTr("No earned trophies yet")
                    if (filterMode === "not_earned") return qsTr("All trophies earned!")
                    return qsTr("No trophies")
                }
                font.pixelSize: 16
                opacity: 0.5
                visible: trophyList.count === 0
                }
                
                // Loading indicator
                BusyIndicator {
                anchors.centerIn: parent
                    running: !trophyData
                    visible: running
                }
                
            // Keyboard/gamepad navigation
            Keys.onUpPressed: (event) => {
                if (currentIndex > 0) {
                    currentIndex--
                    event.accepted = true
                } else {
                    // At top of list, go to filter/sort buttons
                    sortDefaultButton.forceActiveFocus()
                    event.accepted = true
                }
            }
            
            Keys.onDownPressed: (event) => {
                if (currentIndex < count - 1) {
                    currentIndex++
                    event.accepted = true
                }
            }
            
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_PageUp) {
                    if (allTrophyGroups.length > 1 && currentGroupIndex > 0) {
                        currentGroupIndex--
                        event.accepted = true
                    }
                } else if (event.key === Qt.Key_PageDown) {
                    if (allTrophyGroups.length > 1 && currentGroupIndex < allTrophyGroups.length - 1) {
                        currentGroupIndex++
                        event.accepted = true
                    }
                }
            }
        }
    }
    
    standardButtons: Dialog.Close
    
    // Ensure focus on trophy list when dialog opens
    Component.onCompleted: {
        if (trophyList.count > 0) {
            trophyList.forceActiveFocus()
        }
    }
}
