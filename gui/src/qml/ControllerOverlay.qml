import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

// Simple controller overlay - shows how to open stream menu
Item {
    id: root
    
    signal dismissed()
    property bool active: false
    
    visible: active
    enabled: active
    
    // Dark background
    Rectangle {
        anchors.fill: parent
        color: "#000000"
        opacity: 0.85
    }
    
    // Everything centered in one container
    Item {
        anchors.centerIn: parent
        width: 1000
        height: 600
        
        // L1 - Top Left
        Label {
            x: 100
            y: 0
            width: 100
            text: "(bumper)"
            font.pixelSize: 14
            color: "#888888"
            horizontalAlignment: Text.AlignHCenter
        }
        
        Rectangle {
            id: l1Button
            x: 100
            y: 22
            width: 100
            height: 60
            color: "#1a1a1a"
            border.color: Material.accent
            border.width: 3
            radius: 8
            
            Label {
                anchors.centerIn: parent
                text: "L1"
                font.pixelSize: 28
                font.bold: true
                color: Material.accent
            }
        }
        
        // R1 - Top Right
        Label {
            x: 800
            y: 0
            width: 100
            text: "(bumper)"
            font.pixelSize: 14
            color: "#888888"
            horizontalAlignment: Text.AlignHCenter
        }
        
        Rectangle {
            id: r1Button
            x: 800
            y: 22
            width: 100
            height: 60
            color: "#1a1a1a"
            border.color: Material.accent
            border.width: 3
            radius: 8
            
            Label {
                anchors.centerIn: parent
                text: "R1"
                font.pixelSize: 28
                font.bold: true
                color: Material.accent
            }
        }
        
        // L3 - Center Left (stick click) - aligned under L1
        Rectangle {
            id: l3Button
            x: 105  // Centered under L1 (150 - 45)
            y: 270
            width: 90
            height: 90
            radius: 45
            color: "#1a1a1a"
            border.color: Material.accent
            border.width: 3
            
            Label {
                anchors.centerIn: parent
                text: "L3"
                font.pixelSize: 26
                font.bold: true
                color: Material.accent
            }
        }
        
        Label {
            x: l3Button.x - 20
            y: l3Button.y + l3Button.height + 5
            width: l3Button.width + 40
            text: "(click stick)"
            font.pixelSize: 14
            color: "#888888"
            horizontalAlignment: Text.AlignHCenter
        }
        
        // R3 - Center Right (stick click) - aligned under R1
        Rectangle {
            id: r3Button
            x: 805  // Centered under R1 (850 - 45)
            y: 270
            width: 90
            height: 90
            radius: 45
            color: "#1a1a1a"
            border.color: Material.accent
            border.width: 3
            
            Label {
                anchors.centerIn: parent
                text: "R3"
                font.pixelSize: 26
                font.bold: true
                color: Material.accent
            }
        }
        
        Label {
            x: r3Button.x - 20
            y: r3Button.y + r3Button.height + 5
            width: r3Button.width + 40
            text: "(click stick)"
            font.pixelSize: 14
            color: "#888888"
            horizontalAlignment: Text.AlignHCenter
        }
        
        // Center instruction box
        Rectangle {
            id: instructionBox
            anchors.centerIn: parent
            width: 400
            height: 200
            color: "#1a1a1a"
            border.color: Material.accent
            border.width: 2
            radius: 15
            
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 15
                
                Label {
                    Layout.alignment: Qt.AlignHCenter
                    text: qsTr("Press L1 + R1")
                    font.pixelSize: 28
                    font.bold: true
                    color: "#ffffff"
                }
                
                Label {
                    Layout.alignment: Qt.AlignHCenter
                    text: qsTr("and L3 + R3")
                    font.pixelSize: 28
                    font.bold: true
                    color: "#ffffff"
                }
                
                
                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    width: 100
                    height: 2
                    color: Material.accent
                    opacity: 0.5
                }
                
                Label {
                    Layout.alignment: Qt.AlignHCenter
                    text: qsTr("To open Stream Menu")
                    font.pixelSize: 20
                    font.bold: true
                    color: Material.accent
                }
            }
        }
        
        // Angled lines connecting L1/R1 to center box
        // L1 to center box (angled inward)
        Canvas {
            anchors.fill: parent
            onPaint: {
                var ctx = getContext("2d");
                ctx.strokeStyle = Material.accent;
                ctx.lineWidth = 3;
                
                // L1 line - from bottom center of L1 to top left of instruction box
                ctx.beginPath();
                ctx.moveTo(l1Button.x + l1Button.width/2, l1Button.y + l1Button.height);
                ctx.lineTo(instructionBox.x, instructionBox.y);
                ctx.stroke();
            }
        }
        
        // R1 to center box (angled inward)
        Canvas {
            anchors.fill: parent
            onPaint: {
                var ctx = getContext("2d");
                ctx.strokeStyle = Material.accent;
                ctx.lineWidth = 3;
                
                // R1 line - from bottom center of R1 to top right of instruction box
                ctx.beginPath();
                ctx.moveTo(r1Button.x + r1Button.width/2, r1Button.y + r1Button.height);
                ctx.lineTo(instructionBox.x + instructionBox.width, instructionBox.y);
                ctx.stroke();
            }
        }
        
        // Left stick to center
        Rectangle {
            x: l3Button.x + l3Button.width
            y: l3Button.y + l3Button.height/2 - 1.5
            width: instructionBox.x - (l3Button.x + l3Button.width)
            height: 3
            color: Material.accent
        }
        
        // Right stick to center
        Rectangle {
            x: instructionBox.x + instructionBox.width
            y: r3Button.y + r3Button.height/2 - 1.5
            width: r3Button.x - (instructionBox.x + instructionBox.width)
            height: 3
            color: Material.accent
        }
    }
    
    // Dismiss button at bottom
    Button {
        id: dismissButton
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: 50
        width: 240
        height: 55
        text: qsTr("Dismiss (Press B)")
        font.pixelSize: 20
        font.bold: true
        Material.background: Material.accent
        Material.roundedScale: Material.MediumScale
        
        onClicked: root.dismiss()
        Keys.onReturnPressed: root.dismiss()
        Keys.onEscapePressed: root.dismiss()
        
        Component.onCompleted: {
            if (root.active)
                forceActiveFocus()
        }
    }
    
    Keys.onEscapePressed: dismiss()
    
    function dismiss() {
        active = false;
        dismissed();
    }
    
    onActiveChanged: {
        if (active)
            dismissButton.forceActiveFocus()
    }
    
    opacity: active ? 1.0 : 0.0
    Behavior on opacity {
        NumberAnimation { duration: 300 }
    }
}
