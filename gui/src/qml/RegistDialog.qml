import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

import "controls" as C

DialogView {
    property bool ps5: true
    property alias host: hostField.text

    title: qsTr("Register Console")
    buttonText: qsTr("Register")
    buttonEnabled: {
        if (!hostField.text.trim()) return false;
        if (!pin.acceptableInput) return false;
        if (!cpin.acceptableInput) return false;
        
        // Always require online ID or account ID based on console selection
        if (ps4_7.checked) {
            // PS4 < 7.0 requires online ID
            return onlineId.text.trim();
        } else {
            // PS4 >= 7.0 and PS5 require account ID (either from PSN or manual lookup)
            return accountId.text.trim() || Chiaki.settings.psnAccountId;
        }
    }
    StackView.onActivated: {
        if(Chiaki.settings.psnAccountId)
            accountId.text = Chiaki.settings.psnAccountId
    }
    onAccepted: {
        let psnId = onlineId.visible ? onlineId.text.trim() : accountId.text.trim();
        let registerOk = Chiaki.registerHost(hostField.text.trim(), psnId, pin.text.trim(), cpin.text.trim(), hostField.text.trim() == "255.255.255.255", consoleButtons.checkedButton.target, function(msg, ok, done) {
            if (!done)
                logArea.text += msg + "\n";
            else
                logDialog.standardButtons = Dialog.Close;
        });
        if (registerOk) {
            logArea.text = "";
            logDialog.open();
        }
    }

    Item {
        GridLayout {
            anchors {
                top: parent.top
                horizontalCenter: parent.horizontalCenter
                topMargin: 20
            }
            columns: 2
            rowSpacing: 10
            columnSpacing: 20

            Label {
                Layout.alignment: Qt.AlignRight
                text: qsTr("Host:")
            }

            C.TextField {
                id: hostField
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                Layout.preferredWidth: 400
                firstInFocusChain: true
                KeyNavigation.up: root.buttonVisible ? root.okButton : null
                KeyNavigation.down: pin
            }

            Label {
                Layout.alignment: Qt.AlignRight
                text: qsTr("Remote Play PIN:")
            }

            C.TextField {
                id: pin
                validator: RegularExpressionValidator { regularExpression: /[0-9]{8}/ }
                Layout.preferredWidth: 400
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                KeyNavigation.up: hostField
                KeyNavigation.down: ps4_7.checked ? onlineId : byLoginButton
            }

            Label {
                Layout.alignment: Qt.AlignRight
                text: qsTr("Find Account ID:")
                visible: !ps4_7.checked
            }

            RowLayout {
                visible: !ps4_7.checked
                spacing: 10
                Layout.preferredWidth: 400
                
                C.Button {
                    id: byLoginButton
                    text: qsTr("By Login")
                    Layout.preferredWidth: 195
                    height: 40
                    onClicked: {
                        // Use the same pattern as showPSNTokenDialog for consistent behavior
                        stack.push("QRLoginDialog.qml", {callback: (id) => {
                            // If QR login succeeds with an account ID, use it
                            if (id) {
                                accountId.text = id;
                                return;
                            }
                            // If user chooses "Login on This Device" (callback called with null), show the token dialog
                            stack.push(psnTokenDialogComponent, {psnurl: "", expired: false});
                        }});
                    }
                    Material.roundedScale: Material.MediumScale
                    font.pixelSize: 14
                    
                    KeyNavigation.up: pin
                    KeyNavigation.down: accountId
                    KeyNavigation.right: byLookupButton
                    
                    background: Rectangle {
                        radius: 6
                        color: parent.hovered ? Qt.rgba(0, 212/255, 255/255, 0.3) : Qt.rgba(0, 212/255, 255/255, 0.2)
                        border.color: "#00d4ff"
                        border.width: 2
                    }
                }
                
                C.Button {
                    id: byLookupButton
                    text: qsTr("By Lookup")
                    Layout.preferredWidth: 195
                    height: 40
                    onClicked: stack.push(psnLoginDialogComponent, {login: false, callback: (id) => accountId.text = id})
                    Material.roundedScale: Material.MediumScale
                    font.pixelSize: 14
                    
                    KeyNavigation.up: pin
                    KeyNavigation.down: accountId
                    KeyNavigation.left: byLoginButton
                    
                    background: Rectangle {
                        radius: 6
                        color: parent.hovered ? Qt.rgba(0, 212/255, 255/255, 0.3) : Qt.rgba(0, 212/255, 255/255, 0.2)
                        border.color: "#00d4ff"
                        border.width: 2
                    }
                }
            }

            Label {
                Layout.alignment: Qt.AlignRight
                text: qsTr("Account-ID:")
                visible: !ps4_7.checked
            }

            C.TextField {
                id: accountId
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                placeholderText: qsTr("base64")
                Layout.preferredWidth: 400
                visible: !ps4_7.checked
                KeyNavigation.up: byLoginButton
                KeyNavigation.down: onlineId.visible ? onlineId : cpin
            }

            Label {
                Layout.alignment: Qt.AlignRight
                text: qsTr("Online-ID:")
                visible: onlineId.visible
            }

            C.TextField {
                id: onlineId
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                visible: ps4_7.checked
                placeholderText: qsTr("username, case-sensitive")
                Layout.preferredWidth: 400
                KeyNavigation.up: pin
                KeyNavigation.down: cpin
            }

            Label {
                Layout.alignment: Qt.AlignRight
                text: qsTr("Console Pin [Optional]")
            }

            C.TextField {
                id: cpin
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                validator: RegularExpressionValidator { regularExpression: /^$|[0-9]{4}/ }
                Layout.preferredWidth: 400
                KeyNavigation.up: onlineId.visible ? onlineId : (accountId.visible ? accountId : byLoginButton)
                KeyNavigation.down: ps4_7
            }

            Label {
                Layout.alignment: Qt.AlignRight
                text: qsTr("Console:")
            }

            ColumnLayout {
                spacing: 0

                C.RadioButton {
                    id: ps4_7
                    property int target: 800
                    text: qsTr("PS4 Firmware < 7.0")
                    KeyNavigation.up: cpin
                    KeyNavigation.down: ps4_75
                }

                C.RadioButton {
                    id: ps4_75
                    property int target: 900
                    text: qsTr("PS4 Firmware >= 7.0, < 8.0")
                    KeyNavigation.up: ps4_7
                    KeyNavigation.down: ps4_8
                }

                C.RadioButton {
                    id: ps4_8
                    property int target: 1000
                    text: qsTr("PS4 Firmware >= 8.0")
                    checked: !ps5
                    KeyNavigation.up: ps4_75
                    KeyNavigation.down: ps5_0
                }

                C.RadioButton {
                    id: ps5_0
                    property int target: 1000100
                    text: qsTr("PS5")
                    checked: ps5
                    KeyNavigation.up: ps4_8
                    KeyNavigation.down: root.okButton
                }
            }







        }

        ButtonGroup {
            id: consoleButtons
            buttons: [ps4_7, ps4_75, ps4_8, ps5_0]
        }

        Item {
            Dialog {
                id: logDialog
                parent: Overlay.overlay
                x: Math.round((root.width - width) / 2)
                y: Math.round((root.height - height) / 2)
                title: qsTr("Register Console")
                modal: true
                closePolicy: Popup.NoAutoClose
                standardButtons: Dialog.Cancel
                Material.roundedScale: Material.MediumScale
                onOpened: logArea.forceActiveFocus(Qt.TabFocusReason)
                onClosed: stack.pop();

                Flickable {
                    id: logFlick
                    implicitWidth: 600
                    implicitHeight: 400
                    clip: true
                    contentWidth: logArea.contentWidth
                    contentHeight: logArea.contentHeight
                    flickableDirection: Flickable.AutoFlickIfNeeded
                    ScrollBar.vertical: ScrollBar {
                        id: logScrollbar
                        policy: ScrollBar.AlwaysOn
                        visible: logFlick.contentHeight > logFlick.implicitHeight
                    }

                    Label {
                        id: logArea
                        width: logFlick.width
                        wrapMode: TextEdit.Wrap
                        Keys.onReturnPressed: if (logDialog.standardButtons == Dialog.Close) logDialog.close()
                        Keys.onEscapePressed: logDialog.close()
                        Keys.onPressed: (event) => {
                            switch (event.key) {
                            case Qt.Key_Up:
                                if(logScrollbar.position > 0.001)
                                    logFlick.flick(0, 500);
                                event.accepted = true;
                                break;
                            case Qt.Key_Down:
                                if(logScrollbar.position < 1.0 - logScrollbar.size - 0.001)
                                    logFlick.flick(0, -500);
                                event.accepted = true;
                                break;
                            }
                        }
                    }
                }
            }
        }

        Component {
            id: psnLoginDialogComponent
            PSNLoginDialog { }
        }

        Component {
            id: psnTokenDialogComponent
            PSNTokenDialog { }
        }
    }
}
