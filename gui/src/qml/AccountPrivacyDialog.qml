import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material
import "controls" as C

import org.streetpea.chiaking

Dialog {
    id: dialog
    property string upgradeUrl: ""
    property var callback
    property var rejectCallback
    property bool newDialogOpen: false
    property Item restoreFocusItem
    
    title: qsTr("Privacy Settings Required")
    parent: Overlay.overlay
    x: Math.round((root.width - width) / 2)
    y: Math.round((root.height - height) / 2)
    modal: true
    width: 420
    Material.roundedScale: Material.MediumScale
    
    background: Rectangle {
        color: Material.dialogColor
        radius: 12
        border.color: Material.accent
        border.width: 2
    }
    
    onOpened: {
        console.log("AccountPrivacyDialog opened, URL length:", upgradeUrl.length);
        cancelButton.forceActiveFocus(Qt.TabFocusReason);
        if (upgradeUrl && upgradeUrl.length > 0) {
            console.log("Attempting to copy URL to clipboard...");
            Chiaki.setClipboardText(upgradeUrl);
            console.log("Copied URL to clipboard:", upgradeUrl.substring(0, 50) + "...");
        } else {
            console.warn("No URL to copy - upgradeUrl is empty!");
        }
    }
    
    onUpgradeUrlChanged: {
        console.log("upgradeUrl changed, length:", upgradeUrl.length);
        // Also copy when URL changes (in case it's set after dialog opens)
        if (visible && upgradeUrl && upgradeUrl.length > 0) {
            console.log("Copying URL after property change...");
            Chiaki.setClipboardText(upgradeUrl);
        }
    }
    
    onAccepted: {
        newDialogOpen = true;
        restoreFocus();
        if (callback)
            callback();
    }
    
    onRejected: {
        newDialogOpen = true;
        restoreFocus();
        if (rejectCallback)
            rejectCallback();
    }
    
    onClosed: if(!newDialogOpen) { restoreFocus() }

    function restoreFocus() {
        if (restoreFocusItem)
            restoreFocusItem.forceActiveFocus(Qt.TabFocusReason);
        mainLabel.focus = false;
    }

    Component.onCompleted: {
        header.horizontalAlignment = Text.AlignHCenter;
        // Qt 6.6: Workaround dialog background becoming immediately transparent during close animation
        header.background = null;
    }
    
    Shortcut {
        sequence: "Escape"
        enabled: dialog.visible
        onActivated: dialog.reject()
    }
    
    Shortcut {
        sequence: "Back"
        enabled: dialog.visible
        onActivated: dialog.reject()
    }
    
    Shortcut {
        sequence: "Return"
        enabled: dialog.visible
        onActivated: dialog.reject()
    }
    
    // Y button to ignore forever (advanced option)
    Shortcut {
        sequence: "Y"
        enabled: dialog.visible
        onActivated: dialog.accept()
    }
    
    ColumnLayout {
        spacing: 20
        width: parent.width

        Label {
            id: mainLabel
            Layout.fillWidth: true
            text: qsTr("New accounts must save privacy settings before streaming. Scan the QR code below.")
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 13
            Keys.onEscapePressed: dialog.reject()
            Keys.onReturnPressed: dialog.reject()
            Keys.onYesPressed: dialog.accept()
        }

        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 220
            Layout.preferredHeight: 220
            color: "white"
            border.color: Material.accent
            border.width: 2
            radius: 8
            
            Image {
                id: qrCodeImage
                anchors.centerIn: parent
                width: 200
                height: 200
                source: upgradeUrl ? "https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=" + encodeURIComponent(dialog.upgradeUrl) : ""
                fillMode: Image.PreserveAspectFit
                
                BusyIndicator {
                    anchors.centerIn: parent
                    running: qrCodeImage.status === Image.Loading
                    visible: running
                }
            }
        }

        Label {
            Layout.fillWidth: true
            Layout.leftMargin: 10
            Layout.rightMargin: 10
            Layout.bottomMargin: 0
            text: qsTr("URL copied to clipboard")
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 11
            color: Material.accent
            font.italic: true
        }

        // Advanced option hint
        Label {
            Layout.fillWidth: true
            Layout.topMargin: 0
            Layout.leftMargin: 20
            Layout.rightMargin: 20
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            font.pixelSize: 9
            color: Material.foreground
            opacity: 0.4
            
            text: {
                let buttonName = root.controllerButton("pyramid").includes("deck") ? "Y" : 
                               (Chiaki.controllers.length > 0 && Chiaki.controllers[0].playStation ? "△" : "Y");
                return qsTr("(Press %1 to ignore this warning forever)").arg(buttonName);
            }
        }

        RowLayout {
            Layout.alignment: Qt.AlignCenter
            Layout.topMargin: 10

            Button {
                id: cancelButton
                text: qsTr("Close")
                Material.background: Material.accent
                flat: true
                leftPadding: 50
                onClicked: dialog.reject()
                Material.roundedScale: Material.SmallScale

                Image {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                        leftMargin: 12
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: root.controllerButton("cross")
                }
            }
        }
    }
}

