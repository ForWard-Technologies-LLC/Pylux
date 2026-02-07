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
    property alias headerButton: okButton
    property Item restoreFocusItem
    property int toolbarHeight: 80
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
        height: dialog.toolbarHeight
        
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

            // pylux logo and branding (right side) - hide when button is visible
            RowLayout {
                Layout.alignment: Qt.AlignVCenter
                Layout.maximumWidth: 300
                spacing: 15
                visible: !okButton.visible
                
                Column {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.fillWidth: true
                    
                    Label {
                        width: parent.width
                        text: "PYLUX"
                        font.pixelSize: 18
                        font.weight: Font.Bold
                        font.letterSpacing: 1.5
                        color: "#00d4ff"
                        horizontalAlignment: Text.AlignRight
                        elide: Text.ElideRight
                    }
                    Label {
                        width: parent.width
                        text: "Remote Play Client"
                        font.pixelSize: 10
                        font.weight: Font.Light
                        color: Qt.rgba(255, 255, 255, 0.7)
                        font.letterSpacing: 0.8
                        horizontalAlignment: Text.AlignRight
                        elide: Text.ElideRight
                        wrapMode: Text.NoWrap
                    }
                }
                
                Image {
                    Layout.preferredWidth: 50
                    Layout.preferredHeight: 50
                    source: "qrc:icons/logo_square_1024.png"
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    antialiasing: true
                    mipmap: true
                    sourceSize.width: 100
                    sourceSize.height: 100
                }
            }

            // Action button (far right) - controlled by buttonVisible property (default shows if buttonText exists)
            Button {
                id: okButton
                Layout.fillHeight: true
                Layout.preferredWidth: 120
                Layout.preferredHeight: parent.height
                flat: true
                padding: 15
                font.pixelSize: 16
                font.weight: Font.Medium
                focusPolicy: Qt.StrongFocus
                onClicked: dialog.accepted()
                
                // Navigate down to the first focusable item in the main content
                KeyNavigation.down: dialog.mainItem ? dialog.mainItem.nextItemInFocusChain() : null
                
                // Navigate up to main tab bar when in a StackView
                Keys.onUpPressed: (event) => {
                    if (dialog.StackView && dialog.StackView.view && dialog.StackView.view.depth > 0) {
                        let mainView = dialog.StackView.view.get(0);
                        if (mainView && mainView.mainTabBar && mainView.mainTabBar.itemAt(0)) {
                            mainView.mainTabBar.itemAt(0).forceActiveFocus();
                            event.accepted = true;
                        }
                    }
                }
                
                // Handle gamepad A button / keyboard Enter
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Return && enabled) {
                        clicked();
                        event.accepted = true;
                    }
                }
                
                background: Rectangle {
                    radius: 8
                    color: {
                        if (!parent.enabled) return Qt.rgba(0.3, 0.3, 0.3, 0.2);
                        if (parent.activeFocus) return Qt.rgba(0, 212/255, 255/255, 0.4);
                        if (parent.hovered) return Qt.rgba(0, 212/255, 255/255, 0.2);
                        return Qt.rgba(0, 212/255, 255/255, 0.1);
                    }
                    border.color: {
                        if (!parent.enabled) return Qt.rgba(0.5, 0.5, 0.5, 0.5);
                        if (parent.activeFocus) return "#00d4ff";
                        if (parent.hovered) return Qt.rgba(0, 212/255, 255/255, 0.9);
                        return Qt.rgba(0, 212/255, 255/255, 0.8);
                    }
                    border.width: parent.activeFocus ? 3 : 2
                    opacity: parent.enabled ? 1.0 : 0.6
                    
                    Behavior on color { ColorAnimation { duration: 200 } }
                    Behavior on border.color { ColorAnimation { duration: 200 } }
                    Behavior on border.width { NumberAnimation { duration: 200 } }
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                    
                    // Enhanced glow effect when focused
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -2
                        radius: parent.radius + 1
                        color: "transparent"
                        border.color: parent.enabled && parent.activeFocus ? "#00d4ff" : "transparent"
                        border.width: 2
                        opacity: parent.enabled && parent.activeFocus ? 0.8 : 0
                        visible: parent.enabled && parent.activeFocus
                        
                        layer.enabled: parent.enabled && parent.activeFocus
                        layer.effect: MultiEffect {
                            blurEnabled: true
                            blurMax: 8
                            blur: 0.5
                        }
                        
                        Behavior on opacity { NumberAnimation { duration: 200 } }
                    }
                }
                
                contentItem: Text {
                    text: parent.text
                    font: parent.font
                    color: {
                        if (!parent.enabled) return Qt.rgba(0.7, 0.7, 0.7, 0.8);
                        return "#00d4ff";
                    }
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    
                    Behavior on color { ColorAnimation { duration: 200 } }
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
