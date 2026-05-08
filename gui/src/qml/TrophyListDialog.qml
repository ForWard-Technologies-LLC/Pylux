import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

Dialog {
    id: dialog
    
    property string currentNpTitleId: ""  // The ID we use to fetch (e.g., CUSA01163_00)
    property var trophyData: null
    property var allTrophyGroups: []
    property int allTrophyGroupsCount: 0  // Track count separately to force updates
    property int currentGroupIndex: 0
    property string sortMode: "default"  // default (by progress), earned, type
    property string filterMode: "all"  // all, earned, not_earned
    property bool isRefreshing: false
    
    title: ""  // Empty title, we'll use custom header
    modal: true
    width: 900
    height: 700
    
    // Enhanced popup appearance with prominent border
    background: Rectangle {
        color: Material.dialogColor
        radius: 8
        border.width: 3
        border.color: Material.accent
        
        // Outer glow effect
        Rectangle {
            anchors.fill: parent
            anchors.margins: -6
            radius: 10
            color: "transparent"
            border.width: 6
            border.color: Qt.rgba(0, 212/255, 255/255, 0.3)
            z: -1
        }
    }
    
    // Custom header inside the border
    header: Rectangle {
        height: 50
        color: Qt.rgba(0, 212/255, 255/255, 0.1)
        radius: 8
        
        Label {
            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            text: trophyData ? trophyData.trophyTitleName || qsTr("Trophies") : qsTr("Loading Trophies...")
            font.pixelSize: 18
            font.weight: Font.Bold
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            color: Material.accent
        }
    }
    
    // Compact footer inside the border
    footer: Rectangle {
        height: 45
        color: Qt.rgba(0, 0, 0, 0.2)
        radius: 8
        
        // Refresh button on the left
        Button {
            id: footerRefreshButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 20
            text: isRefreshing ? qsTr("Refreshing...") : qsTr("🔄 Refresh")
            font.pixelSize: 13
            enabled: !isRefreshing
            focusPolicy: Qt.StrongFocus
            ToolTip.text: qsTr("Refresh trophy data from server (bypasses 24h cache)")
            ToolTip.visible: hovered || activeFocus
            
            KeyNavigation.up: trophyList
            KeyNavigation.right: footerCloseButton
            
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
            
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Space || event.key === Qt.Key_Enter) {
                    refreshTrophies()
                    event.accepted = true
                }
            }
            
            BusyIndicator {
                anchors.centerIn: parent
                width: 16
                height: 16
                running: isRefreshing
                visible: isRefreshing
            }
        }
        
        // Close button on the right
        Button {
            id: footerCloseButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: 20
            text: qsTr("Close")
            font.pixelSize: 13
            focusPolicy: Qt.StrongFocus
            
            KeyNavigation.up: trophyList
            KeyNavigation.left: footerRefreshButton
            
            onClicked: dialog.close()
            
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Space || event.key === Qt.Key_Enter) {
                    dialog.close()
                    event.accepted = true
                }
            }
            
            background: Rectangle {
                radius: 4
                color: parent.activeFocus ? Qt.rgba(255, 255, 255, 0.15) : Qt.rgba(255, 255, 255, 0.08)
                border.width: parent.activeFocus ? 2 : 1
                border.color: parent.activeFocus ? "#ffffff" : Qt.rgba(255, 255, 255, 0.2)
            }
        }
    }
    
    function showTrophies(npTitleId) {
        if (!npTitleId || npTitleId === "") {
            console.warn("showTrophies: npTitleId is empty, cannot fetch trophies")
            return
        }
        
        currentNpTitleId = npTitleId
        // Clear all data to prevent showing stale data from previous game
        trophyData = null
        allTrophyGroups = []
        allTrophyGroupsCount = 0
        cachedFilteredTrophies = []
        currentGroupIndex = 0
        sortMode = "default"  // Use default (progress-based) sorting
        filterMode = "all"
        isRefreshing = false
        open()
        
        // Request trophy data from games backend (with cache)
        // The backend will convert npTitleId to npCommunicationId internally
        ChiakiGames.fetchTrophyData(npTitleId, false)
    }
    
    function refreshTrophies() {
        isRefreshing = true
        trophyData = null
        allTrophyGroups = []
        allTrophyGroupsCount = 0
        cachedFilteredTrophies = []
        
        // Force refresh (bypass cache) - uses the npTitleId we saved when opening
        ChiakiGames.fetchTrophyData(currentNpTitleId, true)
    }
    
    property var cachedFilteredTrophies: []
    
    // Get stats for currently viewed group
    function getCurrentGroupStats() {
        if (!allTrophyGroups[currentGroupIndex]) {
            return {
                earnedTrophies: trophyData && trophyData.earnedTrophies ? trophyData.earnedTrophies : { platinum: 0, gold: 0, silver: 0, bronze: 0 },
                definedTrophies: trophyData && trophyData.definedTrophies ? trophyData.definedTrophies : { platinum: 0, gold: 0, silver: 0, bronze: 0 },
                progress: trophyData && trophyData.progress ? trophyData.progress : 0
            }
        }
        
        return {
            earnedTrophies: allTrophyGroups[currentGroupIndex].earnedTrophies,
            definedTrophies: allTrophyGroups[currentGroupIndex].definedTrophies,
            progress: allTrophyGroups[currentGroupIndex].progress
        }
    }
    
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
        if (sortMode === "default") {
            // Default: Show trophies with progress first (highest progress first), then by trophy ID
            trophies.sort((a, b) => {
                let aHasProgress = a.progressRate !== undefined && !a.earned
                let bHasProgress = b.progressRate !== undefined && !b.earned
                
                if (aHasProgress && !bHasProgress) return -1
                if (!aHasProgress && bHasProgress) return 1
                if (aHasProgress && bHasProgress) {
                    // Both have progress, sort by progress rate (highest first)
                    return (b.progressRate || 0) - (a.progressRate || 0)
                }
                // Default to trophy ID order
                return (a.trophyId || 0) - (b.trophyId || 0)
            })
        } else if (sortMode === "earned") {
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
    
    onAllTrophyGroupsChanged: {
        // Ensure current index is valid
        if (currentGroupIndex >= allTrophyGroups.length) {
            currentGroupIndex = 0
        }
    }
    
    onCurrentGroupIndexChanged: {
        // Ensure index is valid (but allow 0 even if array is empty)
        if (allTrophyGroups.length > 0 && (currentGroupIndex < 0 || currentGroupIndex >= allTrophyGroups.length)) {
            currentGroupIndex = 0
            return
        }
        
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
            // The backend returns data keyed by the npTitleId we sent (e.g., CUSA01163_00)
            if (npTitleId === currentNpTitleId) {
                try {
                    let parsed = JSON.parse(data)
                    trophyData = parsed
                    
                    // Check if there's an error or no trophies
                    if (!parsed.trophies || !Array.isArray(parsed.trophies) || parsed.trophies.length === 0) {
                        // Clear everything and reset state
                        currentGroupIndex = 0
                        allTrophyGroups = []
                        allTrophyGroupsCount = 0
                        cachedFilteredTrophies = []
                        trophyList.model = null
                        trophyList.model = []
                        return
                    }
                    
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
                                    totalCount: 0,
                                    earnedTrophies: { platinum: 0, gold: 0, silver: 0, bronze: 0 },
                                    definedTrophies: { platinum: 0, gold: 0, silver: 0, bronze: 0 }
                                }
                            }
                            groups[groupId].trophies.push(trophy)
                            groups[groupId].totalCount++
                            
                            // Count defined trophies by type
                            let trophyType = (trophy.trophyType || "").toLowerCase()
                            if (trophyType === "platinum") groups[groupId].definedTrophies.platinum++
                            else if (trophyType === "gold") groups[groupId].definedTrophies.gold++
                            else if (trophyType === "silver") groups[groupId].definedTrophies.silver++
                            else if (trophyType === "bronze") groups[groupId].definedTrophies.bronze++
                            
                            // Count earned trophies
                            if (trophy.earned === true) {
                                groups[groupId].earnedCount++
                                if (trophyType === "platinum") groups[groupId].earnedTrophies.platinum++
                                else if (trophyType === "gold") groups[groupId].earnedTrophies.gold++
                                else if (trophyType === "silver") groups[groupId].earnedTrophies.silver++
                                else if (trophyType === "bronze") groups[groupId].earnedTrophies.bronze++
                            }
                        }
                        
                        // Calculate progress for each group
                        for (let groupId in groups) {
                            let group = groups[groupId]
                            group.progress = group.totalCount > 0 ? Math.round((group.earnedCount / group.totalCount) * 100) : 0
                        }
                        
                        // Convert to array
                        let groupsArray = Object.values(groups)
                        
                        // Assign new trophy groups AND explicitly set count
                        allTrophyGroups = groupsArray
                        allTrophyGroupsCount = groupsArray.length
                        
                        // Initial cache and force model update
                        cachedFilteredTrophies = getCurrentTrophies()
                        trophyList.model = null  // Force refresh
                        trophyList.model = cachedFilteredTrophies
                        
                        // Set focus to first trophy item after data loads
                        Qt.callLater(() => {
                            if (trophyList.count > 0) {
                                trophyList.currentIndex = 0
                                trophyList.forceActiveFocus(Qt.TabFocusReason)
                            }
                        })
                    }
                } catch (e) {
                    console.error("Failed to parse trophy data:", e)
                    // Clear everything on error
                    currentGroupIndex = 0
                    allTrophyGroups = []
                    allTrophyGroupsCount = 0
                    cachedFilteredTrophies = []
                    trophyList.model = null
                    trophyList.model = []
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
                footerCloseButton.forceActiveFocus()
            }
        })
    }
    
    onClosed: {
        // Clear all data when dialog closes to prevent stale data from showing
        trophyData = null
        allTrophyGroups = []
        allTrophyGroupsCount = 0
        cachedFilteredTrophies = []
        currentGroupIndex = 0
        sortMode = "default"
        filterMode = "all"
    }
    
    contentItem: ColumnLayout {
        spacing: 0
        
        // Trophy Summary Header
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 100
            color: Qt.rgba(0, 212/255, 255/255, 0.05)
            
            RowLayout {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 32
                
                // Platinum
                ColumnLayout {
                    spacing: 4
                    Label {
                        text: {
                            let stats = getCurrentGroupStats()
                            return stats.earnedTrophies.platinum + "/" + stats.definedTrophies.platinum
                        }
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
                        text: {
                            let stats = getCurrentGroupStats()
                            return stats.earnedTrophies.gold + "/" + stats.definedTrophies.gold
                        }
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
                        text: {
                            let stats = getCurrentGroupStats()
                            return stats.earnedTrophies.silver + "/" + stats.definedTrophies.silver
                        }
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
                        text: {
                            let stats = getCurrentGroupStats()
                            return stats.earnedTrophies.bronze + "/" + stats.definedTrophies.bronze
                        }
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
                        text: {
                            let stats = getCurrentGroupStats()
                            return stats.progress + "%"
                        }
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
            visible: allTrophyGroupsCount > 1
            
            ScrollView {
                anchors.fill: parent
                contentWidth: groupTabs.implicitWidth
                ScrollBar.vertical.policy: ScrollBar.AlwaysOff
                
                Row {
                    id: groupTabs
                    anchors.fill: parent
                    spacing: 0
                    
                    Repeater {
                        id: groupTabsRepeater
                        model: allTrophyGroupsCount
                        
                        delegate: Button {
                            required property int index
                            
                            height: 50
                            flat: true
                            text: {
                                if (index < allTrophyGroups.length && allTrophyGroups[index]) {
                                    let group = allTrophyGroups[index]
                                    return group.groupName + " (" + group.earnedCount + "/" + group.totalCount + ")"
                                }
                                return ""
                            }
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
                        ToolTip.text: qsTr("Sort by progress (highest first), then by trophy ID")
                        ToolTip.visible: hovered || activeFocus
                        
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
                        
                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Space || event.key === Qt.Key_Enter) {
                                sortMode = "default"
                                event.accepted = true
                            }
                        }
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
                        
                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Space || event.key === Qt.Key_Enter) {
                                sortMode = "earned"
                                event.accepted = true
                            }
                        }
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
                        
                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Space || event.key === Qt.Key_Enter) {
                                sortMode = "type"
                                event.accepted = true
                            }
                        }
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
                        
                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Space || event.key === Qt.Key_Enter) {
                                filterMode = "all"
                                event.accepted = true
                            }
                        }
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
                        
                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Space || event.key === Qt.Key_Enter) {
                                filterMode = "earned"
                                event.accepted = true
                            }
                        }
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
                        
                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Space || event.key === Qt.Key_Enter) {
                                filterMode = "not_earned"
                                event.accepted = true
                            }
                        }
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
                height: 110  // Increased height to accommodate new fields
                
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
                        
                        // Trophy Description
                            Label {
                                Layout.fillWidth: true
                                text: modelData.trophyDetail || ""
                                font.pixelSize: 12
                                opacity: 0.7
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }
                            
                        // Trophy Stats Row (Earned Rate, Rarity, Hidden, Progress)
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            
                            // Earned Rate (what % of players earned this)
                            Rectangle {
                                Layout.preferredWidth: earnedContent.implicitWidth + 10
                                Layout.preferredHeight: 18
                                radius: 3
                                visible: !!(modelData.trophyEarnedRate !== undefined)
                                color: Qt.rgba(0, 212/255, 255/255, 0.15)
                                border.width: 1
                                border.color: Qt.rgba(0, 212/255, 255/255, 0.4)
                                
                                RowLayout {
                                    id: earnedContent
                                    anchors.centerIn: parent
                                    spacing: 4
                                    
                                    Label {
                                        text: "🌍"
                                        font.pixelSize: 9
                                    }
                                    
                                    Label {
                                        text: (modelData.trophyEarnedRate || "0") + "% of players"
                                        font.pixelSize: 9
                                        font.weight: Font.DemiBold
                                        color: Material.accent
                                    }
                                }
                            }
                            
                            // Rarity Badge
                            Rectangle {
                                Layout.preferredWidth: rarityContent.implicitWidth + 10
                                Layout.preferredHeight: 18
                                radius: 3
                                visible: !!(modelData.trophyRare !== undefined)
                                color: {
                                    let rare = modelData.trophyRare
                                    if (rare === 0) return Qt.rgba(138/255, 43/255, 226/255, 0.3)  // Ultra Rare - purple
                                    if (rare === 1) return Qt.rgba(255/255, 0, 0, 0.3)  // Very Rare - red
                                    if (rare === 2) return Qt.rgba(255/255, 165/255, 0, 0.3)  // Rare - orange
                                    return Qt.rgba(76/255, 175/255, 80/255, 0.3)  // Common - green
                                }
                                border.width: 1
                                border.color: {
                                    let rare = modelData.trophyRare
                                    if (rare === 0) return Qt.rgba(138/255, 43/255, 226/255, 0.8)
                                    if (rare === 1) return Qt.rgba(255/255, 0, 0, 0.8)
                                    if (rare === 2) return Qt.rgba(255/255, 165/255, 0, 0.8)
                                    return Qt.rgba(76/255, 175/255, 80/255, 0.8)
                                }
                                
                                RowLayout {
                                    id: rarityContent
                                    anchors.centerIn: parent
                                    spacing: 3
                                    
                                    Label {
                                        text: {
                                            let rare = modelData.trophyRare
                                            if (rare === 0) return "💎"
                                            if (rare === 1) return "⭐"
                                            if (rare === 2) return "✨"
                                            return "●"
                                        }
                                        font.pixelSize: 9
                                    }
                                    
                                    Label {
                                        text: {
                                            let rare = modelData.trophyRare
                                            if (rare === 0) return qsTr("Ultra Rare")
                                            if (rare === 1) return qsTr("Very Rare")
                                            if (rare === 2) return qsTr("Rare")
                                            return qsTr("Common")
                                        }
                                        font.pixelSize: 9
                                        font.weight: Font.DemiBold
                                        color: {
                                            let rare = modelData.trophyRare
                                            if (rare === 0) return Qt.rgba(138/255, 43/255, 226/255, 1)
                                            if (rare === 1) return Qt.rgba(255/255, 0, 0, 1)
                                            if (rare === 2) return Qt.rgba(255/255, 165/255, 0, 1)
                                            return Qt.rgba(76/255, 175/255, 80/255, 1)
                                        }
                                    }
                                }
                            }
                            
                            // Hidden Badge
                            Rectangle {
                                Layout.preferredWidth: hiddenContent.implicitWidth + 10
                                Layout.preferredHeight: 18
                                radius: 3
                                color: Qt.rgba(255, 152/255, 0, 0.2)
                                border.width: 1
                                border.color: Qt.rgba(255, 152/255, 0, 0.5)
                                visible: !!(modelData.trophyHidden && !modelData.earned)
                                
                                RowLayout {
                                    id: hiddenContent
                                    anchors.centerIn: parent
                                    spacing: 3
                                    
                                    Label {
                                        text: "🔒"
                                        font.pixelSize: 9
                                    }
                                    
                                    Label {
                                        text: qsTr("Hidden")
                                        font.pixelSize: 9
                                        font.weight: Font.DemiBold
                                    color: Qt.rgba(255, 152/255, 0, 1)
                                }
                            }
                        }
                            
                            Item { Layout.fillWidth: true }
                            
                            // Progress Bar (for trackable trophies)
                            RowLayout {
                                spacing: 6
                                visible: !!(modelData.progressRate !== undefined && !modelData.earned)
                                Layout.preferredWidth: 130
                                
                                Label {
                                    text: "📊"
                                    font.pixelSize: 10
                                }
                                
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 16
                                    radius: 8
                                    color: Qt.rgba(0, 0, 0, 0.3)
                                    border.width: 1
                                    border.color: Qt.rgba(0, 212/255, 255/255, 0.4)
                                    
                                    Rectangle {
                                        width: Math.max(16, parent.width * ((modelData.progressRate || 0) / 100))
                                        height: parent.height
                                        radius: parent.radius
                                        color: Material.accent
                                        
                                        Behavior on width {
                                            NumberAnimation { duration: 200 }
                                        }
                                    }
                                    
                                    Label {
                                        anchors.centerIn: parent
                                        text: (modelData.progressRate || 0) + "%"
                                        font.pixelSize: 9
                                        font.weight: Font.Bold
                                        color: "white"
                                        style: Text.Outline
                                        styleColor: "black"
                                    }
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
                    if (allTrophyGroups.length === 0) return qsTr("No trophies found for this game.\nTrophy data may not be available.")
                    if (filterMode === "earned") return qsTr("No earned trophies yet")
                    if (filterMode === "not_earned") return qsTr("All trophies earned!")
                    return qsTr("No trophies")
                }
                font.pixelSize: 16
                opacity: 0.7
                horizontalAlignment: Text.AlignHCenter
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
                } else {
                    // At bottom of list, go to close button
                    footerCloseButton.forceActiveFocus()
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
    
    // Ensure focus on trophy list when dialog opens
    Component.onCompleted: {
        if (trophyList.count > 0) {
            trophyList.forceActiveFocus()
        }
    }
}
