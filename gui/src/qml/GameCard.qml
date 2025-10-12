import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

Rectangle {
    id: card
    
    property var gameData
    property bool isHovered: false
    property bool isCurrentItem: GridView.isCurrentItem || false
    property bool hasFocus: isCurrentItem && GridView.view.activeFocus
    property string cachedImageUrl: ""
    
    signal launchGame(string titleId)
    signal createShortcut(string titleId)
    signal viewTrophies(string titleId, string npCommunicationId)
    
    // Generate controller button icon path
    function getControllerIcon(buttonName) {
        let type = "deck";
        for (let i = 0; i < Chiaki.controllers.length; ++i) {
            if (Chiaki.controllers[i].playStation) {
                type = "ps";
                break;
            }
        }
        return `image://svg/button-${type}#${buttonName}`;
    }
    
    // Listen for image updates from backend
    Connections {
        target: ChiakiGames
        
        function onGameImageUpdated(titleId) {
            if (gameData && gameData.titleId === titleId) {
                cachedImageUrl = ChiakiGames.getGameImage(titleId)
            }
        }
    }
    
    // Initial image load
    Component.onCompleted: {
        if (gameData && gameData.titleId) {
            cachedImageUrl = ChiakiGames.getGameImage(gameData.titleId)
        }
    }
    
    color: isHovered || isCurrentItem ? Qt.lighter(Material.dialogColor, 1.1) : Material.dialogColor
    radius: 8
    border.width: 0
    border.color: "transparent"
    
    Behavior on color { ColorAnimation { duration: 150 } }
    
    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        
        onEntered: isHovered = true
        onExited: isHovered = false
        onClicked: parent.GridView.view.currentIndex = index
    }
    
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8
        
        // Game Image
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 180
            color: "#1a1a1a"
            radius: 4
            
            Image {
                id: gameImage
                anchors.fill: parent
                anchors.margins: 1
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: true
                
                source: cachedImageUrl
                
                BusyIndicator {
                    anchors.centerIn: parent
                    running: gameImage.status === Image.Loading
                    visible: running
                }
                
                Label {
                    anchors.centerIn: parent
                    text: gameData && gameData.comment ? gameData.comment.substring(0, 2) : "?"
                    font.pixelSize: 48
                    font.bold: true
                    opacity: 0.3
                    visible: gameImage.status !== Image.Ready
                }
            }
        }
        
        // Game Title
        Label {
            Layout.fillWidth: true
            text: {
                if (gameData) {
                    if (gameData.comment) return gameData.comment
                    if (gameData.title) return gameData.title
                    if (gameData.name) return gameData.name
                }
                return qsTr("Unknown Game")
            }
            font.pixelSize: 16
            font.bold: true
            elide: Text.ElideRight
            maximumLineCount: 2
            wrapMode: Text.Wrap
        }
        
        // Trophy Progress
        Label {
            Layout.fillWidth: true
            text: {
                if (gameData && gameData.npTitleId && gameData.trophyProgress !== undefined) {
                    return qsTr("%1% Trophies").arg(gameData.trophyProgress)
                }
                return ""
            }
            font.pixelSize: 12
            opacity: 0.7
            color: Material.accent
            visible: !!(gameData && gameData.npTitleId && gameData.trophyProgress !== undefined)
        }
        
        Item { Layout.fillHeight: true }
        
        // Action Buttons
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: true
            
            // Launch Game button
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                radius: 6
                color: launchMouseArea.containsMouse ? Qt.lighter(Material.accent, 1.2) : Material.accent
                
                Behavior on color { ColorAnimation { duration: 150 } }
                
                MouseArea {
                    id: launchMouseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    
                    onClicked: {
                        if (gameData && gameData.titleId) {
                            launchGame(gameData.titleId)
                        }
                    }
                }
                
                Label {
                    anchors.centerIn: parent
                    text: qsTr("Launch Game")
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    color: "white"
                }
            }
            
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                
                // Shortcut button with Square/X icon
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 36
                    radius: 6
                    color: shortcutMouseArea.containsMouse ? Qt.rgba(255, 255, 255, 0.3) : Qt.rgba(255, 255, 255, 0.15)
                    border.width: 1
                    border.color: Qt.rgba(255, 255, 255, 0.2)
                    
                    Behavior on color { ColorAnimation { duration: 150 } }
                    
                    MouseArea {
                        id: shortcutMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        
                        onClicked: {
                            if (gameData && gameData.titleId) {
                                createShortcut(gameData.titleId)
                            }
                        }
                    }
                    
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 8
                        
                        Label {
                            Layout.fillWidth: true
                            text: qsTr("Shortcut")
                            font.pixelSize: 13
                            font.weight: Font.Medium
                            color: "white"
                            horizontalAlignment: Text.AlignLeft
                            verticalAlignment: Text.AlignVCenter
                        }
                        
                        Image {
                            Layout.preferredWidth: 22
                            Layout.preferredHeight: 22
                            sourceSize: Qt.size(44, 44)
                            source: getControllerIcon("box")
                            opacity: 0.9
                            smooth: true
                            antialiasing: true
                        }
                    }
                }
                
                // Trophies button with Triangle/Y icon
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 36
                    radius: 6
                    color: trophiesMouseArea.containsMouse ? Qt.rgba(255, 255, 255, 0.3) : Qt.rgba(255, 255, 255, 0.15)
                    border.width: 1
                    border.color: Qt.rgba(255, 255, 255, 0.2)
                    visible: !!(gameData && gameData.npTitleId)
                    
                    Behavior on color { ColorAnimation { duration: 150 } }
                    
                    MouseArea {
                        id: trophiesMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: !!(gameData && gameData.npTitleId)
                        
                        onClicked: {
                            if (gameData && gameData.titleId && gameData.npTitleId) {
                                viewTrophies(gameData.titleId, gameData.npTitleId)
                            }
                        }
                    }
                    
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 8
                        
                        Label {
                            Layout.fillWidth: true
                            text: qsTr("Trophies")
                            font.pixelSize: 13
                            font.weight: Font.Medium
                            color: "white"
                            horizontalAlignment: Text.AlignLeft
                            verticalAlignment: Text.AlignVCenter
                        }
                        
                        Image {
                            Layout.preferredWidth: 22
                            Layout.preferredHeight: 22
                            sourceSize: Qt.size(44, 44)
                            source: getControllerIcon("pyramid")
                            opacity: 0.9
                            smooth: true
                            antialiasing: true
                        }
                    }
                }
            }
        }
    }
    
    Keys.onPressed: (event) => {
        // Cross/A button (Enter/Space) - Launch game
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Space || event.key === Qt.Key_Enter) {
            if (gameData && gameData.titleId) {
                launchGame(gameData.titleId)
                event.accepted = true
            }
        }
        // Square/X button (X key) - Create shortcut
        else if (event.key === Qt.Key_X) {
            if (gameData && gameData.titleId) {
                createShortcut(gameData.titleId)
                event.accepted = true
            }
        }
        // Triangle/Y button (Y key) - View trophies
        else if (event.key === Qt.Key_Y) {
            if (gameData && gameData.titleId && gameData.npTitleId) {
                viewTrophies(gameData.titleId, gameData.npTitleId)
                event.accepted = true
            }
        }
    }
}

