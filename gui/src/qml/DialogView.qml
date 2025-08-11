import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Effects

Item {
    id: dialog
    property alias header: headerLabel.text
    property alias title: titleLabel.text
    property alias buttonText: okButton.text
    property alias buttonEnabled: okButton.enabled
    property alias buttonVisible: okButton.visible
    property Item restoreFocusItem
    default property Item mainItem: null

    signal accepted()
    signal rejected()
    
    // Clean blue background
    CleanBlueBackground {
        anchors.fill: parent
        z: -2
    }
    
    // Dark overlay for better text contrast
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.4)
        z: -1
    }
    
    // Dark overlay for better contrast
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(10/255, 15/255, 26/255, 0.4)
        border.color: Qt.rgba(0, 212/255, 255/255, 0.2)
        border.width: 1
        z: 0
    }

    function close() {
        root.closeDialog();
    }

    Keys.onEscapePressed: close()

    Keys.onMenuPressed: {
        if (okButton.enabled)
            okButton.clicked()
    }

    StackView.onDeactivating: {
        restoreFocusItem = Window.window.activeFocusItem;
    }

    StackView.onActivated: {
        if (!restoreFocusItem) {
            let item = mainItem.nextItemInFocusChain();
            if (item)
                item.forceActiveFocus(Qt.TabFocusReason);
        } else {
            restoreFocusItem.forceActiveFocus(Qt.TabFocusReason);
            restoreFocusItem = null;
        }
    }

    onMainItemChanged: {
        if (mainItem) {
            mainItem.parent = contentItem;
            mainItem.anchors.fill = contentItem;
        }
    }

    ToolBar {
        id: toolBar
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
        }
        height: 80
        
        Material.background: "#0a0f1a"
        Material.foreground: "#ffffff"
        
        background: Rectangle {
            color: "#0a0f1a"
            border.color: Qt.rgba(0, 212/255, 255/255, 0.2)
            border.width: 1
        }

        RowLayout {
            anchors {
                fill: parent
                leftMargin: 15
                rightMargin: 15
            }

            // Back button (far left)
            Button {
                Layout.fillHeight: true
                Layout.preferredWidth: 80
                flat: true
                text: "❮"
                focusPolicy: Qt.NoFocus
                font.pixelSize: 20
                onClicked: {
                    dialog.rejected();
                    dialog.close();
                }
                
                background: Rectangle {
                    radius: 8
                    color: parent.hovered ? Qt.rgba(0, 212/255, 255/255, 0.1) : "transparent"
                    border.color: parent.hovered ? "#00d4ff" : "transparent"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 200 } }
                    Behavior on border.color { ColorAnimation { duration: 200 } }
                }
                
                contentItem: Text {
                    text: parent.text
                    font: parent.font
                    color: "#00d4ff"
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Item { Layout.fillWidth: true }

            // PSStream logo and branding (right side)
            RowLayout {
                Layout.alignment: Qt.AlignVCenter
                spacing: 15
                
                Column {
                    Layout.alignment: Qt.AlignVCenter
                    
                    Label {
                        text: "PSSTREAM"
                        font.pixelSize: 18
                        font.weight: Font.Bold
                        font.letterSpacing: 1.5
                        color: "#00d4ff"
                        horizontalAlignment: Text.AlignRight
                    }
                    Label {
                        text: "PlayStation Remote Play"
                        font.pixelSize: 10
                        font.weight: Font.Light
                        color: Qt.rgba(255, 255, 255, 0.7)
                        font.letterSpacing: 0.8
                        horizontalAlignment: Text.AlignRight
                    }
                }
                
                Rectangle {
                    Layout.preferredWidth: 50
                    Layout.preferredHeight: 50
                    radius: 8
                    color: Qt.rgba(0, 212/255, 255/255, 0.1)
                    border.color: "#00d4ff"
                    border.width: 2
                    opacity: 0.8
                    
                    Text {
                        anchors.centerIn: parent
                        text: "PS"
                        font.pixelSize: 18
                        font.weight: Font.Bold
                        color: "#00d4ff"
                    }
                    
                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: "transparent"
                        border.color: "#00d4ff"
                        border.width: 2
                        opacity: 0.3
                        
                        layer.enabled: true
                        layer.effect: MultiEffect {
                            blurEnabled: true
                            blurMax: 8
                            blur: 0.4
                        }
                    }
                }
            }

            // Action button (far right)
            Button {
                id: okButton
                Layout.fillHeight: true
                Layout.preferredWidth: 100
                flat: true
                padding: 15
                font.pixelSize: 20
                focusPolicy: Qt.NoFocus
                onClicked: dialog.accepted()
                icon.source: "qrc:/icons/options.svg";
                icon.width: 35
                icon.height: 35
                
                background: Rectangle {
                    radius: 8
                    color: parent.hovered ? Qt.rgba(0, 212/255, 255/255, 0.1) : "transparent"
                    border.color: parent.hovered ? "#00d4ff" : "transparent"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 200 } }
                    Behavior on border.color { ColorAnimation { duration: 200 } }
                }
            }
        }

        Label {
            id: titleLabel
            anchors {
                horizontalCenter: parent.horizontalCenter
                verticalCenter: parent.verticalCenter
            }
            horizontalAlignment: Qt.AlignHCenter
            verticalAlignment: Qt.AlignVCenter
            font.bold: true
            font.pixelSize: 20
            color: "#00d4ff"
            font.letterSpacing: 1
        }

        Label {
            id: headerLabel
            anchors {
                top: titleLabel.bottom
                horizontalCenter: parent.horizontalCenter
                topMargin: 5
            }
            horizontalAlignment: Qt.AlignHCenter
            verticalAlignment: Qt.AlignVCenter
            font.bold: false
            font.pixelSize: 12
            color: Qt.rgba(255, 255, 255, 0.7)
            font.letterSpacing: 0.5
        }
    }

    Item {
        id: contentItem
        anchors {
            top: toolBar.bottom
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        
        // Ensure content area is transparent to show dark background
        clip: true
    }
}
