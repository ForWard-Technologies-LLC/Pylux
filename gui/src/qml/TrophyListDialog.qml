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
    
    title: trophyData ? trophyData.trophyTitleName || qsTr("Trophies") : qsTr("Loading Trophies...")
    modal: true
    width: 800
    height: 600
    
    function showTrophies(titleId, npCommunicationId) {
        currentTitleId = titleId
        currentNpCommunicationId = npCommunicationId
        trophyData = null
        open()
        
        // Request trophy data from games backend
        ChiakiGames.fetchTrophyData(npCommunicationId)
    }
    
    Connections {
        target: ChiakiGames
        
        function onTrophyDataReceived(npCommId, data) {
            if (npCommId === currentNpCommunicationId) {
                try {
                    trophyData = JSON.parse(data)
                } catch (e) {
                    console.error("Failed to parse trophy data:", e)
                }
            }
        }
    }
    
    contentItem: ColumnLayout {
        spacing: 16
        
        // Trophy Summary
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 80
            color: Material.dialogColor
            radius: 4
            visible: trophyData
            
            RowLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 24
                
                // Platinum
                ColumnLayout {
                    spacing: 4
                    Label {
                        text: trophyData && trophyData.earnedTrophies ? trophyData.earnedTrophies.platinum || 0 : 0
                        font.pixelSize: 24
                        font.bold: true
                        color: "#E5E5E5"
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Label {
                        text: qsTr("Platinum")
                        font.pixelSize: 12
                        opacity: 0.7
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
                
                // Gold
                ColumnLayout {
                    spacing: 4
                    Label {
                        text: trophyData && trophyData.earnedTrophies ? trophyData.earnedTrophies.gold || 0 : 0
                        font.pixelSize: 24
                        font.bold: true
                        color: "#FFD700"
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Label {
                        text: qsTr("Gold")
                        font.pixelSize: 12
                        opacity: 0.7
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
                
                // Silver
                ColumnLayout {
                    spacing: 4
                    Label {
                        text: trophyData && trophyData.earnedTrophies ? trophyData.earnedTrophies.silver || 0 : 0
                        font.pixelSize: 24
                        font.bold: true
                        color: "#C0C0C0"
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Label {
                        text: qsTr("Silver")
                        font.pixelSize: 12
                        opacity: 0.7
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
                
                // Bronze
                ColumnLayout {
                    spacing: 4
                    Label {
                        text: trophyData && trophyData.earnedTrophies ? trophyData.earnedTrophies.bronze || 0 : 0
                        font.pixelSize: 24
                        font.bold: true
                        color: "#CD7F32"
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Label {
                        text: qsTr("Bronze")
                        font.pixelSize: 12
                        opacity: 0.7
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
                
                Item { Layout.fillWidth: true }
                
                // Progress
                ColumnLayout {
                    spacing: 4
                    Label {
                        text: trophyData && trophyData.progress ? trophyData.progress + "%" : "0%"
                        font.pixelSize: 32
                        font.bold: true
                        color: Material.accent
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Label {
                        text: qsTr("Complete")
                        font.pixelSize: 12
                        opacity: 0.7
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
            }
        }
        
        // Trophy List
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            
            ColumnLayout {
                width: parent.width
                spacing: 8
                
                Label {
                    text: qsTr("All Trophies")
                    font.pixelSize: 16
                    font.bold: true
                    visible: trophyData
                }
                
                Repeater {
                    model: [] // TODO: Implement trophy list from API
                    
                    delegate: Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 80
                        color: Material.dialogColor
                        radius: 4
                        
                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 16
                            
                            // Trophy Icon
                            Image {
                                Layout.preferredWidth: 56
                                Layout.preferredHeight: 56
                                source: modelData.trophyIconUrl || ""
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                            }
                            
                            // Trophy Info
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 4
                                
                                Label {
                                    text: modelData.trophyName || ""
                                    font.pixelSize: 14
                                    font.bold: true
                                }
                                
                                Label {
                                    text: modelData.trophyDetail || ""
                                    font.pixelSize: 12
                                    opacity: 0.7
                                    wrapMode: Text.Wrap
                                    Layout.fillWidth: true
                                }
                            }
                            
                            // Trophy Type
                            Label {
                                text: modelData.trophyType || ""
                                font.pixelSize: 12
                                font.capitalization: Font.Capitalize
                            }
                        }
                    }
                }
                
                // Loading indicator
                BusyIndicator {
                    Layout.alignment: Qt.AlignHCenter
                    running: !trophyData
                    visible: running
                }
                
                Label {
                    Layout.alignment: Qt.AlignHCenter
                    text: qsTr("No trophies available")
                    visible: trophyData && (!trophyData.definedTrophies || trophyData.definedTrophies.length === 0)
                    opacity: 0.7
                }
            }
        }
    }
    
    standardButtons: Dialog.Close
}

