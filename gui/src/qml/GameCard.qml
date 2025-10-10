import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

Rectangle {
    id: card
    
    property var gameData
    property bool isHovered: false
    property bool hasFocus: activeFocus
    
    signal launchGame(string titleId)
    signal createShortcut(string titleId)
    signal viewTrophies(string titleId, string npCommunicationId)
    
    color: isHovered || hasFocus ? Qt.lighter(Material.dialogColor, 1.1) : Material.dialogColor
    radius: 8
    border.width: hasFocus ? 3 : 1
    border.color: hasFocus ? Material.accent : Qt.rgba(1, 1, 1, 0.1)
    
    Behavior on border.width { NumberAnimation { duration: 150 } }
    Behavior on color { ColorAnimation { duration: 150 } }
    
    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        
        onEntered: isHovered = true
        onExited: isHovered = false
        onClicked: card.forceActiveFocus()
    }
    
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8
        
        // Game Image
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 140
            color: "#1a1a1a"
            radius: 4
            
            Image {
                id: gameImage
                anchors.fill: parent
                anchors.margins: 1
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: true
                
                source: {
                    if (!gameData || !gameData.titleId) return ""
                    // Request image from games backend
                    return ChiakiGames.getGameImage(gameData.titleId)
                }
                
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
            text: gameData && gameData.comment ? gameData.comment : qsTr("Unknown Game")
            font.pixelSize: 16
            font.bold: true
            elide: Text.ElideRight
            maximumLineCount: 2
            wrapMode: Text.Wrap
        }
        
        // Trophy Progress
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: gameData && gameData.npTitleId
            
            Image {
                Layout.preferredWidth: 16
                Layout.preferredHeight: 16
                source: "qrc:/icons/trophy.png"
                visible: false // TODO: Add trophy icon
            }
            
            Label {
                text: qsTr("Trophies")
                font.pixelSize: 12
                opacity: 0.7
            }
            
            Item { Layout.fillWidth: true }
        }
        
        Item { Layout.fillHeight: true }
        
        // Action Buttons (shown on hover/focus)
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6
            visible: isHovered || hasFocus
            
            Button {
                Layout.fillWidth: true
                text: qsTr("Launch Game")
                Material.background: Material.accent
                onClicked: {
                    if (gameData && gameData.titleId) {
                        launchGame(gameData.titleId)
                    }
                }
            }
            
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                
                Button {
                    Layout.fillWidth: true
                    text: qsTr("Add Shortcut")
                    flat: true
                    onClicked: {
                        if (gameData && gameData.titleId) {
                            createShortcut(gameData.titleId)
                        }
                    }
                }
                
                Button {
                    Layout.fillWidth: true
                    text: qsTr("View Trophies")
                    flat: true
                    visible: gameData && gameData.npTitleId
                    onClicked: {
                        if (gameData && gameData.titleId && gameData.npTitleId) {
                            viewTrophies(gameData.titleId, gameData.npTitleId)
                        }
                    }
                }
            }
        }
    }
    
    Keys.onReturnPressed: {
        if (gameData && gameData.titleId) {
            launchGame(gameData.titleId)
        }
    }
    
    Keys.onSpacePressed: {
        if (gameData && gameData.titleId) {
            launchGame(gameData.titleId)
        }
    }
}

