import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Effects

import org.streetpea.chiaking

Pane {
    id: root
    padding: 0
    
    property string deviceId: ""  // Device ID to filter games for
    property string deviceName: ""
    property int serverIndex: -1  // Server index for connecting
    property int currentPage: 0
    property int gamesPerPage: 25
    property var allGames: []
    property var currentPageGames: []
    
    function goBack() {
        StackView.view.pop()
    }
    
    function controllerButton(name) {
        let type = "deck";
        for (let i = 0; i < Chiaki.controllers.length; ++i) {
            if (Chiaki.controllers[i].playStation) {
                type = "ps";
                break;
            }
        }
        return `image://svg/button-${type}#${name}`;
    }
    
    Component.onCompleted: {
        loadGames()
    }
    
    StackView.onActivated: {
        Qt.callLater(() => {
            if (gamesGrid.count > 0) {
                gamesGrid.forceActiveFocus()
            }
        })
    }
    
    function loadGames() {
        let gamesJson = deviceId ? ChiakiGames.getGamesForDevice(deviceId) : Chiaki.getPsnInstalledGames()
        if (!gamesJson || gamesJson === "{}") {
            allGames = []
            currentPageGames = []
            return
        }
        
        try {
            // If we got games for a specific device, it's already an array
            if (deviceId) {
                allGames = JSON.parse(gamesJson)
                updateCurrentPage()
                return
            }
            
            // Otherwise, flatten all games from all devices
            let devices = JSON.parse(gamesJson)
            let gamesList = []
            
            for (let deviceId in devices) {
                let device = devices[deviceId]
                if (device.games && Array.isArray(device.games)) {
                    gamesList = gamesList.concat(device.games)
                }
            }
            
            allGames = gamesList
            updateCurrentPage()
        } catch (e) {
            console.error("Failed to parse games JSON:", e)
            allGames = []
            currentPageGames = []
        }
    }
    
    function updateCurrentPage() {
        let startIdx = currentPage * gamesPerPage
        let endIdx = Math.min(startIdx + gamesPerPage, allGames.length)
        currentPageGames = allGames.slice(startIdx, endIdx)
    }
    
    function nextPage() {
        if ((currentPage + 1) * gamesPerPage < allGames.length) {
            currentPage++
            updateCurrentPage()
        }
    }
    
    function previousPage() {
        if (currentPage > 0) {
            currentPage--
            updateCurrentPage()
        }
    }
    
    // Clean blue background - same as main view
    CleanBlueBackground {
        anchors.fill: parent
        z: -2
    }
    
    // Header toolbar
    Rectangle {
        id: toolBar
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
        }
        height: 70
        
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: Qt.rgba(0, 212/255, 255/255, 0.15) }
            GradientStop { position: 1.0; color: Qt.rgba(0, 212/255, 255/255, 0.05) }
        }
        
        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(10/255, 20/255, 38/255, 0.9)
        }
        
        // Glowing border effect
        Rectangle {
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            height: 2
            color: "#50d4ff"
            opacity: 0.7
            
            Rectangle {
                anchors.fill: parent
                color: "#50d4ff"
                layer.enabled: true
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blurMax: 16
                    blur: 0.8
                }
            }
        }
        
        RowLayout {
            anchors {
                fill: parent
                leftMargin: 20
                rightMargin: 20
                topMargin: 5
                bottomMargin: 5
            }
            spacing: 15
            
            Button {
                id: backButton
                text: qsTr("← Back")
                onClicked: root.goBack()
                font.pixelSize: 13
                font.weight: Font.Medium
                focusPolicy: Qt.StrongFocus
                Layout.preferredHeight: 35
                Layout.preferredWidth: 100
                KeyNavigation.down: gamesGrid
                
                background: Rectangle {
                    radius: 4
                    color: parent.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.3) : Qt.rgba(255, 255, 255, 0.08)
                    border.width: parent.activeFocus ? 2 : 1
                    border.color: parent.activeFocus ? Material.accent : Qt.rgba(255, 255, 255, 0.2)
                }
                
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Space || event.key === Qt.Key_Enter) {
                        root.goBack()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Down) {
                        // Restore selection to first item when navigating down to grid
                        if (gamesGrid.currentIndex === -1) {
                            gamesGrid.currentIndex = 0
                        }
                    }
                }
            }
            
            Label {
                text: deviceName ? qsTr("Games - %1").arg(deviceName) : qsTr("My Games")
                font.pixelSize: 20
                font.bold: true
                color: "white"
            }
            
            Item { Layout.fillWidth: true }
            
            Label {
                text: allGames.length > 0 ? qsTr("%1 games total").arg(allGames.length) : qsTr("No games found")
                font.pixelSize: 13
                opacity: 0.8
                color: "white"
            }
        }
    }
    
    ColumnLayout {
        anchors.top: toolBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.topMargin: 10
        spacing: 0
        
        // Games Grid
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true  // Prevent cards from going over header
            
            ScrollView {
                id: scrollView
                anchors.fill: parent
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                anchors.bottomMargin: 60  // Space for the footer overlay
                clip: true  // Clip scrolling content
                
                // Remove contentWidth to prevent horizontal scrolling
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                contentWidth: scrollView.availableWidth
                
                GridView {
                    id: gamesGrid
                    width: {
                        // Calculate how many columns fit in the available content width
                        // availableWidth accounts for scrollbar space
                        let availableWidth = scrollView.availableWidth
                        let cols = Math.floor(availableWidth / cellWidth)
                        if (cols === 0) cols = 1
                        // Return width for exactly that many columns (centered)
                        return cols * cellWidth
                    }
                    // Height needs to be implicit to enable scrolling
                    height: implicitHeight
                    x: (scrollView.availableWidth - width) / 2
                    cellWidth: 310  // Fit 4 columns on 1280px wide screens
                    cellHeight: 310  // Fit 2 rows on 800px tall screens
                    focus: true
                    clip: false
                    interactive: false  // Disable GridView's own scrolling, let ScrollView handle it
                    flickableDirection: Flickable.VerticalFlick  // Explicitly disable horizontal flicking
                
                model: currentPageGames
                highlightFollowsCurrentItem: true
                keyNavigationEnabled: true
                keyNavigationWraps: false
                
                // Highlight rectangle for keyboard/gamepad navigation
                highlight: Rectangle {
                    color: "transparent"
                    border.color: Material.accent
                    border.width: 3
                    radius: 8
                    z: 10
                }
                
                delegate: GameCard {
                    required property int index
                    required property var modelData
                    width: gamesGrid.cellWidth - 20
                    height: gamesGrid.cellHeight - 20
                    gameData: modelData
                    focus: true
                    activeFocusOnTab: true
                    
                onLaunchGame: (titleId) => {
                    console.log("Launch game:", titleId)
                    let game = modelData
                    let gameName = game.comment || game.titleName || "Unknown Game"
                    console.log("Launching game:", gameName, "with titleId:", titleId, "on device:", root.deviceId)
                    
                    if (root.serverIndex >= 0) {
                        // Connect to host with game name and title ID to trigger automation and show game image
                        // Pass deviceName (console nickname) for wakeup support
                        Chiaki.connectToHost(root.serverIndex, root.deviceName, gameName, titleId)
                    } else {
                        console.error("No server index available for launching game")
                    }
                }
                    
                onCreateShortcut: (titleId) => {
                    console.log("GamesView: onCreateShortcut called with titleId:", titleId)
                    let game = modelData
                    let gameName = game.comment || game.titleName || "Unknown Game"
                    console.log("GamesView: gameName:", gameName)
                    console.log("GamesView: calling gameShortcutDialog.showDialog")
                    gameShortcutDialog.showDialog(gameName, titleId, root.deviceName)
                    console.log("GamesView: showDialog call returned")
                }
                    
                    onViewTrophies: (npTitleId) => {
                        // npTitleId is what we get from the game data (e.g., CUSA01163_00)
                        // The backend will convert it to npCommunicationId internally
                        trophyDialog.showTrophies(npTitleId)
                    }
                }
                
                Keys.onPressed: (event) => {
                    if (event.modifiers)
                        return;
                    
                    let cols = Math.floor(scrollView.availableWidth / cellWidth)
                    if (cols === 0) cols = 1
                    
                    // Handle up navigation to back button when on first row
                    if (event.key === Qt.Key_Up) {
                        // If current index is in the first row
                        if (currentIndex < cols) {
                            currentIndex = -1  // Clear selection to remove highlight
                            backButton.forceActiveFocus()
                            event.accepted = true
                            return
                        }
                    }
                    
                    // Handle down navigation to partial rows
                    if (event.key === Qt.Key_Down) {
                        let totalItems = model.length
                        let currentRow = Math.floor(currentIndex / cols)
                        let nextRowStartIndex = (currentRow + 1) * cols
                        let nextRowEndIndex = Math.min(nextRowStartIndex + cols - 1, totalItems - 1)
                        
                        // If there's a next row with items
                        if (nextRowStartIndex < totalItems) {
                            let colInRow = currentIndex % cols
                            let targetIndex = nextRowStartIndex + colInRow
                            
                            // If target column exists in next row, go there
                            if (targetIndex <= nextRowEndIndex) {
                                currentIndex = targetIndex
                            } else {
                                // Otherwise go to the last item in next row
                                currentIndex = nextRowEndIndex
                            }
                            event.accepted = true
                            return
                        }
                    }
                    
                    switch (event.key) {
                    case Qt.Key_Escape:
                    case Qt.Key_Back:
                        // Navigate back to main view
                        event.accepted = true
                        root.goBack()
                        break;
                    case Qt.Key_Backslash:
                    case Qt.Key_No:
                        // X/Square button - Create shortcut for current game
                        if (currentItem && currentItem.gameData) {
                            let game = currentItem.gameData
                            let titleId = game.titleId
                            let gameName = game.comment || game.titleName || "Unknown Game"
                            gameShortcutDialog.showDialog(gameName, titleId, root.deviceName)
                            event.accepted = true
                        }
                        break;
                    case Qt.Key_C:
                    case Qt.Key_Yes:
                        // Y/Triangle button - View trophies for current game
                        if (currentItem) {
                            // Get game data from either gameData or modelData
                            let game = currentItem.gameData || currentItem.modelData
                            if (game && game.npTitleId) {
                                trophyDialog.showTrophies(game.npTitleId)
                                event.accepted = true
                            }
                        }
                        break;
                    }
                }
                
                Component.onCompleted: {
                    if (count > 0) {
                        currentIndex = 0
                        forceActiveFocus()
                    }
                }
            }
            }
        }
        
        // Pagination Footer
        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: 20
            Layout.leftMargin: 40
            Layout.rightMargin: 40
            visible: allGames.length > gamesPerPage
            
            Button {
                text: qsTr("← Previous")
                enabled: currentPage > 0
                onClicked: previousPage()
            }
            
            Item { Layout.fillWidth: true }
            
            Label {
                text: qsTr("Page %1 of %2").arg(currentPage + 1).arg(Math.ceil(allGames.length / gamesPerPage))
                font.pixelSize: 16
            }
            
            Item { Layout.fillWidth: true }
            
            Button {
                text: qsTr("Next →")
                enabled: (currentPage + 1) * gamesPerPage < allGames.length
                onClicked: nextPage()
            }
        }
    }
    
    // Trophy Dialog
    TrophyListDialog {
        id: trophyDialog
        anchors.centerIn: parent
        
        onClosed: {
            // Restore focus to games grid after dialog closes
            Qt.callLater(() => {
                if (gamesGrid.count > 0) {
                    gamesGrid.forceActiveFocus(Qt.TabFocusReason)
                }
            })
        }
    }
    
    // Game Shortcut Dialog
    GameShortcutDialog {
        id: gameShortcutDialog
        anchors.centerIn: parent
        
        onShowToast: (message, color) => {
            toastLabel.text = message
            toast.color = color
            toastTimer.restart()
        }
        
        onAllDialogsClosed: {
            // Restore focus to games grid after all dialogs close
            Qt.callLater(() => {
                if (gamesGrid.count > 0) {
                    gamesGrid.forceActiveFocus(Qt.TabFocusReason)
                }
            })
        }
        
        onClosed: {
            // Restore focus to games grid after dialog closes
            Qt.callLater(() => {
                if (gamesGrid.count > 0) {
                    gamesGrid.forceActiveFocus(Qt.TabFocusReason)
                }
            })
        }
    }
    
    // Button hints overlay
    Rectangle {
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        height: 40
        color: Qt.rgba(0, 0, 0, 0.6)
        visible: allGames.length > 0  // Always show when there are games
        z: 100  // Ensure it's above other content
        
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 15
            anchors.rightMargin: 15
            anchors.topMargin: 8
            anchors.bottomMargin: 8
            spacing: 20
            
            // Launch hint
            RowLayout {
                spacing: 6
                Image {
                    Layout.preferredWidth: 18
                    Layout.preferredHeight: 18
                    sourceSize: Qt.size(36, 36)
                    source: root.controllerButton("cross")
                    opacity: 0.9
                    smooth: true
                    antialiasing: true
                }
                Label {
                    text: qsTr("Launch")
                    font.pixelSize: 13
                    font.weight: Font.Medium
                    color: "white"
                }
            }
            
            // Shortcut hint
            RowLayout {
                spacing: 6
                Image {
                    Layout.preferredWidth: 18
                    Layout.preferredHeight: 18
                    sourceSize: Qt.size(36, 36)
                    source: root.controllerButton("box")
                    opacity: 0.9
                    smooth: true
                    antialiasing: true
                }
                Label {
                    text: qsTr("Shortcut")
                    font.pixelSize: 13
                    font.weight: Font.Medium
                    color: "white"
                }
            }
            
            // Trophies hint
            RowLayout {
                spacing: 6
                Image {
                    Layout.preferredWidth: 18
                    Layout.preferredHeight: 18
                    sourceSize: Qt.size(36, 36)
                    source: root.controllerButton("pyramid")
                    opacity: 0.9
                    smooth: true
                    antialiasing: true
                }
                Label {
                    text: qsTr("Trophies")
                    font.pixelSize: 13
                    font.weight: Font.Medium
                    color: "white"
                }
            }
            
            Item { Layout.fillWidth: true }
            
            // Back hint
            RowLayout {
                spacing: 6
                Image {
                    Layout.preferredWidth: 18
                    Layout.preferredHeight: 18
                    sourceSize: Qt.size(36, 36)
                    source: root.controllerButton("moon")
                    opacity: 0.9
                    smooth: true
                    antialiasing: true
                }
                Label {
                    text: qsTr("Back")
                    font.pixelSize: 13
                    font.weight: Font.Medium
                    color: "white"
                }
            }
        }
    }
    
    // Toast notification (like on Main.qml)
    Rectangle {
        id: toast
        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
            bottomMargin: 80
        }
        color: Material.accent
        width: toastLabel.width + 40
        height: toastLabel.height + 20
        radius: 8
        opacity: toastTimer.running ? 0.8 : 0.0
        z: 1000
        
        Behavior on opacity { NumberAnimation { duration: 300 } }
        Behavior on color { ColorAnimation { duration: 300 } }
        
        Label {
            id: toastLabel
            anchors.centerIn: parent
            text: ""
            font.pixelSize: 16
            font.weight: Font.Medium
            color: "white"
            padding: 10
        }
        
        Timer {
            id: toastTimer
            interval: 3000
        }
    }
}

