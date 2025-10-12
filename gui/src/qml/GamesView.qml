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
        height: 100
        
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
            color: "#00d4ff"
            opacity: 0.7
            
            Rectangle {
                anchors.fill: parent
                color: "#00d4ff"
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
                leftMargin: 25
                rightMargin: 25
                topMargin: 15
                bottomMargin: 15
            }
            spacing: 20
            
            Button {
                text: qsTr("← Back")
                onClicked: root.goBack()
                font.pixelSize: 14
                font.weight: Font.Medium
                focusPolicy: Qt.StrongFocus
                Layout.preferredHeight: 45
                Layout.preferredWidth: 120
            }
            
            Label {
                text: deviceName ? qsTr("Games - %1").arg(deviceName) : qsTr("My Games")
                font.pixelSize: 28
                font.bold: true
                color: "white"
            }
            
            Item { Layout.fillWidth: true }
            
            Label {
                text: allGames.length > 0 ? qsTr("%1 games total").arg(allGames.length) : qsTr("No games found")
                font.pixelSize: 16
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
        anchors.topMargin: 20
        spacing: 0
        
        // Games Grid
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: 20
            Layout.rightMargin: 20
            
            contentWidth: availableWidth
            
            GridView {
                id: gamesGrid
                anchors.fill: parent
                cellWidth: 280
                cellHeight: 380
                focus: true
                clip: true
                
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
                    console.log("Launching game:", gameName, "on device:", root.deviceId)
                    
                    if (root.serverIndex >= 0) {
                        // Connect to host with game name to trigger automation
                        Chiaki.connectToHost(root.serverIndex, "", gameName)
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
                    
                    onViewTrophies: (titleId, npCommunicationId) => {
                        trophyDialog.showTrophies(titleId, npCommunicationId)
                    }
                }
                
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                        // Navigate back to main view
                        event.accepted = true
                        root.goBack()
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
    }
    
    // Game Shortcut Dialog
    GameShortcutDialog {
        id: gameShortcutDialog
        
        onShowToast: (message, color) => {
            toastLabel.text = message
            toast.color = color
            toastTimer.restart()
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
        visible: gamesGrid.activeFocus && allGames.length > 0
        
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

