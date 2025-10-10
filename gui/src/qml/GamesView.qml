import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

Item {
    id: root
    
    property string deviceId: ""  // Device ID to filter games for
    property string deviceName: ""
    property int currentPage: 0
    property int gamesPerPage: 25
    property var allGames: []
    property var currentPageGames: []
    
    Component.onCompleted: {
        loadGames()
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
    
    // Background
    Rectangle {
        anchors.fill: parent
        color: Material.background
    }
    
    ColumnLayout {
        anchors.fill: parent
        spacing: 20
        
        // Header
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 20
            Layout.leftMargin: 40
            Layout.rightMargin: 40
            
            Label {
                text: deviceName ? qsTr("Games - %1").arg(deviceName) : qsTr("My Games")
                font.pixelSize: 32
                font.bold: true
            }
            
            Item { Layout.fillWidth: true }
            
            Label {
                text: allGames.length > 0 ? qsTr("%1 games total").arg(allGames.length) : qsTr("No games found")
                font.pixelSize: 16
                opacity: 0.7
            }
        }
        
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
                cellHeight: 320
                focus: true
                
                model: currentPageGames
                
                delegate: GameCard {
                    width: gamesGrid.cellWidth - 20
                    height: gamesGrid.cellHeight - 20
                    gameData: modelData
                    
                    onLaunchGame: (titleId) => {
                        console.log("Launch game:", titleId)
                        // TODO: Implement game launch
                    }
                    
                    onCreateShortcut: (titleId) => {
                        console.log("Create shortcut:", titleId)
                        // TODO: Implement shortcut creation
                    }
                    
                    onViewTrophies: (titleId, npCommunicationId) => {
                        trophyDialog.showTrophies(titleId, npCommunicationId)
                    }
                }
                
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                        // Navigate back to main view
                        event.accepted = true
                        // TODO: Implement back navigation
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
}

