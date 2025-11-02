import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

import "controls" as C

DialogView {
    id: dialog
    property var callback: null
    property string qrCode: ""
    property bool isProcessing: false
    property bool isCheckingStatus: false
    title: qsTr("PSN Login")
    buttonVisible: false

    StackView.onActivated: {
        // Reset states
        isProcessing = false;
        isCheckingStatus = false;
        statusLabel.visible = false;
        
        // Generate 6-digit alphanumeric code when dialog opens
        qrCode = Chiaki.generateQRCode();
        // Create the code on the server
        createCodeOnServer();
        checkButton.forceActiveFocus(Qt.TabFocusReason);
    }

    function close() {
        root.closeDialog();
    }

    function fallbackToWebLogin() {
        // Close this dialog and call the callback with null to indicate fallback
        dialog.close();
        if (callback) {
            callback(null); // Signal fallback to web login
        }
    }

    function refreshQRCode() {
        if (isProcessing) return;
        
        qrCode = Chiaki.generateQRCode();
        createCodeOnServer();
    }

    function createCodeOnServer() {
        console.log("Creating PSStream code on server:", qrCode);
        Chiaki.createPSStreamCode(qrCode, function(success, errorMsg) {
            if (success) {
                console.log("PSStream code created successfully on server");
                // Optionally show success message to user
                // root.showMessageDialog(qsTr("Success"), qsTr("QR code generated successfully. Scan with your mobile device."));
            } else {
                console.error("Failed to create PSStream code:", errorMsg);
                // Show error to user
                root.showMessageDialog(qsTr("Error"), qsTr("Failed to create login code: %1").arg(errorMsg), () => {});
            }
        });
    }

    function checkStatus() {
        if (isProcessing || isCheckingStatus) return;
        
        console.log("Checking PSStream status for code:", qrCode);
        isCheckingStatus = true;
        
        // Show status checking message to user
        statusLabel.text = qsTr("Checking login status...");
        statusLabel.visible = true;
        
        Chiaki.checkPSStreamStatus(qrCode, function(success, errorMsg, tokens) {
            console.log("PSStream API response - success:", success, "error:", errorMsg, "tokens:", tokens);
            
            isCheckingStatus = false;
            
            if (success && tokens) {
                console.log("PSStream login successful! Processing tokens:", tokens);
                
                // Validate that tokens is a proper redirect URL
                if (tokens.startsWith("https://remoteplay.dl.playstation.net/remoteplay/redirect")) {
                    console.log("Valid PSN redirect URL detected, processing...");
                    isProcessing = true;
                    statusLabel.text = qsTr("Processing login tokens...");
                    statusLabel.visible = true;
                    
                    // Handle the PSN redirect URL using the existing flow
                    // This will trigger the psnLoginAccountIdDone signal that we'll handle
                    if (Chiaki.handlePsnLoginRedirect(tokens)) {
                        console.log("PSN login redirect processing started successfully!");
                        // Don't close the dialog here - let the signal handler do it
                    } else {
                        console.error("Failed to handle PSN login redirect");
                        isProcessing = false;
                        statusLabel.visible = false;
                        root.showMessageDialog(qsTr("Login Error"), qsTr("Invalid redirect URL. Please ensure the redirect URL you copied is valid and up to date. Try generating a new QR code."), () => {});
                    }
                } else {
                    console.error("Invalid token format received:", tokens);
                    statusLabel.visible = false;
                    root.showMessageDialog(qsTr("Login Error"), qsTr("Invalid token format received from server"), () => {});
                }
            } else if (!success) {
                if (errorMsg === "No tokens found for this code") {
                    // This is normal - user hasn't completed login yet
                    console.log("No tokens yet, user still needs to complete mobile login");
                    statusLabel.visible = false;
                    root.showMessageDialog(qsTr("Sign-in Pending"), qsTr("Code not found. Please complete the sign-in process on your mobile device first."), () => {});
                } else {
                    console.error("Failed to check PSStream status:", errorMsg);
                    statusLabel.visible = false;
                    root.showMessageDialog(qsTr("Error"), qsTr("Failed to check login status: %1").arg(errorMsg), () => {});
                }
            }
        });
    }

    // Main content with proper layout
    Item {
        anchors.fill: parent

        // Signal connections to handle PSN login success/error
        Connections {
            target: Chiaki

            function onPsnLoginAccountIdDone(accountId) {
                console.log("QR Login: PSN account ID received:", accountId);
                isProcessing = false;
                statusLabel.visible = false;
                
                // Show success dialog
                root.showMessageDialog(
                    qsTr("Login Successful!"), 
                    qsTr("PSN login completed successfully! You can now connect to your console from the main menu."), 
                    () => {
                        if (callback) {
                            callback(accountId);
                        }
                        dialog.close();
                        root.showMainView();
                    }
                );
            }

            function onPsnLoginAccountIdError(error) {
                console.error("QR Login: PSN account ID error:", error);
                isProcessing = false;
                statusLabel.visible = false;
                root.showMessageDialog(qsTr("PSN Login Error"), qsTr("Invalid redirect URL. Please ensure the redirect URL you copied is valid and up to date. Try generating a new QR code."), () => {});
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.margins: 30
            spacing: 20

            // Left side - QR Code
            Item {
                Layout.fillHeight: true
                Layout.fillWidth: true
                Layout.preferredWidth: parent.width / 2

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 20
                    spacing: 25

                    // Top spacer to center content vertically
                    Item {
                        Layout.fillHeight: true
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: qsTr("Scan with Mobile Device")
                        font.pointSize: 18
                        font.weight: Font.Bold
                        color: Material.foreground
                        Layout.bottomMargin: 10
                    }

                    // QR Code container
                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: 350
                        Layout.preferredHeight: 350
                        color: "white"
                        border.color: Material.accent
                        border.width: 2
                        radius: 12

                        Image {
                            id: qrCodeImage
                            anchors.centerIn: parent
                            width: 320
                            height: 320
                            source: "https://api.qrserver.com/v1/create-qr-code/?size=320x320&data=" + encodeURIComponent(Chiaki.getPSStreamURL() + "/psstream/?psstream_code=" + dialog.qrCode)
                            fillMode: Image.PreserveAspectFit
                            cache: false

                            BusyIndicator {
                                anchors.centerIn: parent
                                running: qrCodeImage.status === Image.Loading
                                visible: running
                            }

                            Label {
                                anchors.centerIn: parent
                                text: qsTr("QR Code Error")
                                visible: qrCodeImage.status === Image.Error
                                color: Material.color(Material.Red)
                            }
                        }
                    }

                    // Code display - more subtle
                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: 15
                        Layout.preferredWidth: 200
                        height: codeLabel.implicitHeight + 12
                        color: Material.color(Material.Grey, Material.Shade900)
                        border.color: Material.color(Material.Grey, Material.Shade600)
                        border.width: 1
                        radius: 4

                        Label {
                            id: codeLabel
                            anchors.centerIn: parent
                            text: qsTr("Code: %1").arg(dialog.qrCode)
                            font.pointSize: 12
                            font.weight: Font.Normal
                            font.family: "monospace"
                            color: Material.color(Material.Grey, Material.Shade300)
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }

                    // Action buttons row
                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: 20
                        spacing: 20

                        C.Button {
                            id: checkButton
                            text: qsTr("Check Status")
                            Layout.preferredWidth: 140
                            Layout.preferredHeight: 40
                            highlighted: true
                            Material.background: Material.accent
                            Material.foreground: "white"
                            font.pointSize: 12
                            font.weight: Font.Medium
                            focus: true
                            enabled: !isProcessing && !isCheckingStatus
                            onClicked: {
                                checkStatus();
                            }
                            KeyNavigation.right: refreshButton
                            
                            Keys.onPressed: function(event) {
                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                    if (enabled) checkStatus();
                                    event.accepted = true;
                                }
                                if (event.key === Qt.Key_Escape) {
                                    dialog.close();
                                    event.accepted = true;
                                }
                            }

                            // Loading indicator for check button
                            BusyIndicator {
                                anchors.centerIn: parent
                                running: isCheckingStatus
                                visible: running
                                width: 20
                                height: 20
                            }
                        }

                        C.Button {
                            id: refreshButton
                            text: qsTr("Refresh Code")
                            Layout.preferredWidth: 140
                            Layout.preferredHeight: 40
                            flat: true
                            font.pointSize: 12
                            enabled: !isProcessing && !isCheckingStatus
                            onClicked: refreshQRCode()
                            KeyNavigation.left: checkButton
                            KeyNavigation.right: loginButton
                            
                            Keys.onPressed: function(event) {
                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                    if (enabled) refreshQRCode();
                                    event.accepted = true;
                                }
                                if (event.key === Qt.Key_Escape) {
                                    dialog.close();
                                    event.accepted = true;
                                }
                            }
                        }
                    }

                    // Bottom spacer to center content vertically
                    Item {
                        Layout.fillHeight: true
                    }
                }
            }

            // Vertical divider
            Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: 2
                Layout.topMargin: 40
                Layout.bottomMargin: 40
                color: Material.color(Material.Grey, Material.Shade500)
                opacity: 0.6
            }

            // Right side - Alternative Login
            Item {
                Layout.fillHeight: true
                Layout.fillWidth: true
                Layout.preferredWidth: parent.width / 2

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 20
                    spacing: 25

                    // Top spacer to center content vertically
                    Item {
                        Layout.fillHeight: true
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: qsTr("Alternative Login")
                        font.pointSize: 18
                        font.weight: Font.Bold
                        color: Material.foreground
                        Layout.bottomMargin: 15
                    }

                    // Alternative login section
                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: childrenRect.height + 40

                        ColumnLayout {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: 20
                            spacing: 15

                            Label {
                                text: qsTr("Don't have a mobile device handy?")
                                font.pointSize: 12
                                Layout.alignment: Qt.AlignHCenter
                                color: Material.color(Material.Grey, Material.Shade300)
                            }

                            C.Button {
                                id: loginButton
                                text: qsTr("Login on This Device")
                                Layout.alignment: Qt.AlignHCenter
                                Layout.preferredWidth: 220
                                Layout.preferredHeight: 45
                                Material.background: Material.color(Material.Grey, Material.Shade700)
                                Material.foreground: Material.foreground
                                font.pointSize: 12
                                enabled: !isProcessing && !isCheckingStatus
                                onClicked: fallbackToWebLogin()
                                KeyNavigation.left: refreshButton
                                KeyNavigation.down: cancelButton
                                
                                Keys.onPressed: function(event) {
                                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                        if (enabled) fallbackToWebLogin();
                                        event.accepted = true;
                                    }
                                    if (event.key === Qt.Key_Escape) {
                                        dialog.close();
                                        event.accepted = true;
                                    }
                                }
                            }

                            C.Button {
                                id: cancelButton
                                text: qsTr("Cancel")
                                Layout.alignment: Qt.AlignHCenter
                                Layout.preferredWidth: 220
                                Layout.preferredHeight: 45
                                flat: true
                                font.pointSize: 12
                                enabled: !isProcessing
                                onClicked: dialog.close()
                                KeyNavigation.up: loginButton
                                KeyNavigation.left: refreshButton
                                
                                Keys.onPressed: function(event) {
                                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                        if (enabled) dialog.close();
                                        event.accepted = true;
                                    }
                                    if (event.key === Qt.Key_Escape) {
                                        if (enabled) dialog.close();
                                        event.accepted = true;
                                    }
                                }
                            }
                        }
                    }

                    // Bottom spacer to center content vertically
                    Item {
                        Layout.fillHeight: true
                    }
                }
            }
        }

    }

    // Status label for showing progress to user
    Rectangle {
        id: statusContainer
        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
            bottomMargin: 20
        }
        visible: statusLabel.visible
        width: statusLabel.implicitWidth + 40
        height: statusLabel.implicitHeight + 20
        color: Material.color(Material.Grey, Material.Shade800)
        radius: 8
        border.color: Material.accent
        border.width: 1

        RowLayout {
            anchors.centerIn: parent
            spacing: 10

            BusyIndicator {
                running: statusLabel.visible
                width: 16
                height: 16
                Layout.alignment: Qt.AlignVCenter
            }

            Label {
                id: statusLabel
                text: ""
                visible: false
                font.pointSize: 12
                color: Material.accent
                Material.theme: Material.Dark
                Layout.alignment: Qt.AlignVCenter
            }
        }
    }
}