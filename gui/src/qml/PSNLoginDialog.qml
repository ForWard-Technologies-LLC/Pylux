import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

import "controls" as C

DialogView {
    id: dialog
    property var callback: null
    property bool login
    property bool submitting: false
    property bool closing: false
    property var psnurl: ""
    title: qsTr("Login")
    buttonVisible: false
    buttonText: qsTr("Get Account ID")
    buttonEnabled: !submitting && url.text.trim()
    onAccepted: {
        submitting = true;
        Chiaki.handlePsnLoginRedirect(url.text.trim());
    }
    StackView.onActivated: {
        if(login)
        {
            nativeLoginForm.visible = true;
            nativeLoginForm.forceActiveFocus(Qt.TabFocusReason);
        }
        else
        {
            accountForm.visible = true
            usernameField.forceActiveFocus(Qt.TabFocusReason)
            usernameField.readOnly = false;
            Qt.inputMethod.show();
        }
    }
    function close() {
        if(webView.web)
        {
            dialog.closing = true;
            if(Chiaki.settings.remotePlayAsk)
                reloadTimer.start();
            else
                cacheClearTimer.start();
        }
        else
            root.closeDialog();
    }

   Item {
        Item {
            id: nativeLoginForm
            Keys.onPressed: (event) => {
                if (event.modifiers)
                    return;
                switch (event.key) {
                case Qt.Key_PageUp:
                    reloadButton.clicked();
                    event.accepted = true;
                    break;
                case Qt.Key_PageDown:
                    extBrowserButton.clicked();
                    event.accepted = true;
                    break;
                }
            }
            anchors.fill: parent
            visible: false
            Rectangle {
                id: psnLoginToolbar
                anchors {
                    bottom: parent.bottom
                    left: parent.left
                    right: parent.right
                    bottomMargin: 20
                    leftMargin: 20
                    rightMargin: 20
                }
                height: 70
                z: 10
                radius: 12
                color: Qt.rgba(10/255, 15/255, 26/255, 0.95)
                border.color: Qt.rgba(0, 212/255, 255/255, 0.4)
                border.width: 1

                // Subtle glow effect
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -2
                    radius: parent.radius + 1
                    color: "transparent"
                    border.color: Qt.rgba(0, 212/255, 255/255, 0.2)
                    border.width: 1
                    z: -1
                }

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 15
                        rightMargin: 15
                        topMargin: 10
                        bottomMargin: 10
                    }
                    spacing: 15
                    
                    Button {
                        id: reloadButton
                        Layout.fillHeight: true
                        Layout.preferredWidth: 220
                        text: "Reload + Clear Cookies"
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        onClicked: reloadTimer.start()
                        focusPolicy: Qt.NoFocus
                        
                        background: Rectangle {
                            radius: 8
                            color: parent.pressed ? Qt.rgba(0, 212/255, 255/255, 0.3) : 
                                   parent.hovered ? Qt.rgba(0, 212/255, 255/255, 0.2) : 
                                   Qt.rgba(0, 212/255, 255/255, 0.1)
                            border.color: Qt.rgba(0, 212/255, 255/255, 0.6)
                            border.width: 1
                            
                            Behavior on color { ColorAnimation { duration: 150 } }
                            Behavior on border.color { ColorAnimation { duration: 150 } }
                        }
                        
                        contentItem: RowLayout {
                            spacing: 8
                            
                            Image {
                                Layout.preferredWidth: 20
                                Layout.preferredHeight: 20
                                sourceSize: Qt.size(width, height)
                                source: "qrc:/icons/l1.svg"
                            }
                            
                            Text {
                                Layout.fillWidth: true
                                text: parent.parent.text
                                font: parent.parent.font
                                color: "#00d4ff"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }
                    
                    // Spacer to push buttons to edges
                    Item {
                        Layout.fillWidth: true
                        
                        ProgressBar {
                            id: browserProgresss
                            anchors.centerIn: parent
                            width: 150
                            height: 6
                            from: 0
                            to: 100
                            value: webView.web ? webView.web.loadProgress : 0
                            focusPolicy: Qt.NoFocus
                            
                            background: Rectangle {
                                radius: 3
                                color: Qt.rgba(255, 255, 255, 0.1)
                                border.color: Qt.rgba(255, 255, 255, 0.2)
                                border.width: 1
                            }
                            
                            contentItem: Item {
                                Rectangle {
                                    width: parent.width * (browserProgresss.value / 100)
                                    height: parent.height
                                    radius: 3
                                    color: Qt.rgba(0, 212/255, 255/255, 0.8)
                                    
                                    Behavior on width { NumberAnimation { duration: 100 } }
                                }
                            }
                        }
                    }
                    Button {
                        id: extBrowserButton
                        Layout.fillHeight: true
                        Layout.preferredWidth: 220
                        text: "Use External Browser"
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        focusPolicy: Qt.NoFocus
                        onClicked: {
                            nativeLoginForm.visible = false;
                            psnLoginToolbar.visible = false;
                            nativeErrorGrid.visible = false;
                            webView.visible = false;
                            loginFormScroll.visible = true;
                            dialog.buttonVisible = true;
                            psnurl = Chiaki.openPsnLink();
                            if(psnurl)
                            {
                                openurl.selectAll();
                                openurl.copy();
                            }
                            pasteUrl.forceActiveFocus(Qt.TabFocusReason);
                        }
                        
                        background: Rectangle {
                            radius: 8
                            color: parent.pressed ? Qt.rgba(100/255, 100/255, 100/255, 0.4) : 
                                   parent.hovered ? Qt.rgba(100/255, 100/255, 100/255, 0.3) : 
                                   Qt.rgba(100/255, 100/255, 100/255, 0.2)
                            border.color: Qt.rgba(150/255, 150/255, 150/255, 0.5)
                            border.width: 1
                            
                            Behavior on color { ColorAnimation { duration: 150 } }
                            Behavior on border.color { ColorAnimation { duration: 150 } }
                        }
                        
                        contentItem: RowLayout {
                            spacing: 8
                            
                            Image {
                                Layout.preferredWidth: 20
                                Layout.preferredHeight: 20
                                sourceSize: Qt.size(width, height)
                                source: "qrc:/icons/r1.svg"
                            }
                            
                            Text {
                                Layout.fillWidth: true
                                text: parent.parent.text
                                font: parent.parent.font
                                color: Qt.rgba(200/255, 200/255, 200/255, 1)
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }
                }
            }
            Timer {
                id: reloadTimer
                interval: 0
                running: false
                onTriggered: {
                    Chiaki.clearCookies(webView.web.profile);
                    webView.web.profile.clearHttpCache();
                }
            }

            Timer {
                id: cacheClearTimer
                interval: 0
                running: false
                onTriggered: {
                    webView.web.profile.clearHttpCache();
                }
            }

            GridLayout {
                id: nativeErrorGrid
                visible: false
                anchors {
                    top: psnLoginToolbar.bottom
                    left: parent.left
                    right: parent.right
                    topMargin: 50
                }
                columns: 2
                rowSpacing: 10
                columnSpacing: 20
                Label {
                    id: nativeErrorHeader
                    text: "Retrieving account ID failed with error: "
                    Layout.fillHeight: true
                    Layout.preferredWidth: 400
                    Layout.leftMargin: 20
                }

                Label {
                    id: nativeErrorLabel
                    Layout.fillHeight: true
                    Layout.preferredWidth: 400
                    Layout.leftMargin: 20
                }

                Label {
                    id: retryButton
                    text: "Retry process"
                    Layout.fillHeight: true
                    Layout.preferredWidth: 300
                    Layout.leftMargin: 20
                }
                C.Button {
                    firstInFocusChain: true
                    lastInFocusChain: true
                    text: "Retry"
                    onClicked: {
                        nativeErrorGrid.visible = false;
                        nativeErrorLabel.text = "";
                        nativeErrorLabel.visible = false;
                        webView.visible = true;
                        webView.web.url = Chiaki.psnLoginUrl();
                    }
                    Layout.preferredWidth: 200
                    Layout.fillHeight: true
                    Layout.leftMargin: 20
                }
            }
            Item {
                id: webView
                property Item web: null
                anchors {
                    top: parent.top
                    bottom: psnLoginToolbar.top
                    left: parent.left
                    right: parent.right
                    leftMargin: 10
                    rightMargin: 10
                }
                Component.onCompleted: {
                    // Always use external browser - don't create WebEngine view
                    extBrowserButton.clicked();
                }
            }
        }
        ScrollView {
            id: loginFormScroll
            anchors {
                top: parent.top
                left: parent.left
                right: parent.right
                bottom: parent.bottom
                topMargin: 50
                leftMargin: 20
                rightMargin: 20
                bottomMargin: 20
            }
            visible: false
            clip: true
            ScrollBar.vertical.policy: ScrollBar.AsNeeded
            
            GridLayout {
                id: loginForm
                width: loginFormScroll.availableWidth
                columns: 2
                rowSpacing: 10
                columnSpacing: 20

            Label {
                id: errorHeader
                visible: false
                text: "Retrieving account ID failed with error"
            }

            Label {
                id: errorLabel
                visible: false
            }

            Label {
                text: qsTr("Open Web Browser with copied URL")
                visible: psnurl
            }

            TextField {
                id: openurl
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                text: psnurl
                visible: false
                Layout.preferredWidth: 400
            }

            C.Button {
                id: copyUrl
                text: qsTr("Click to Re-Copy URL")
                onClicked: {
                    openurl.selectAll()
                    openurl.copy()
                }
                KeyNavigation.priority: KeyNavigation.BeforeItem
                KeyNavigation.up: copyUrl
                KeyNavigation.down: url
                visible: psnurl
            }

            Label {
                text: qsTr("Redirect URL from Web Browser")
            }

            TextField {
                id: url
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                Layout.fillWidth: true
                Layout.maximumWidth: 400
                KeyNavigation.priority: {
                    if(readOnly)
                        KeyNavigation.BeforeItem
                    else
                        KeyNavigation.AfterItem
                }
                KeyNavigation.up: {
                    if(psnurl)
                        copyUrl
                    else
                        url
                }
                KeyNavigation.down: url
                KeyNavigation.right: pasteUrl
                C.Button {
                    id: pasteUrl
                    text: qsTr("Click to Paste URL")
                    anchors {
                        left: parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: 10
                    }
                    KeyNavigation.priority: KeyNavigation.BeforeItem
                    onClicked: url.paste()
                    KeyNavigation.left: url
                    KeyNavigation.up: {
                        if(psnurl)
                            copyUrl
                        else
                            pasteUrl
                    }
                    KeyNavigation.down: npssoToken
                }
            }

            Label {
                text: qsTr("NPSSO Token (Cloud Play Only, Optional)")
                Layout.topMargin: 15
            }

            TextField {
                id: npssoToken
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                text: Chiaki.settings.psnNpssoToken
                Layout.fillWidth: true
                Layout.maximumWidth: 400
                onTextChanged: {
                    // Parse input: extract token from JSON format or use as-is
                    let inputText = text.trim();
                    let token = inputText;
                    
                    // Try to parse as JSON
                    if (inputText.startsWith("{") && inputText.includes("npsso")) {
                        try {
                            let json = JSON.parse(inputText);
                            if (json.npsso) {
                                token = json.npsso;
                            }
                        } catch (e) {
                            // Not valid JSON, use as-is
                        }
                    }
                    
                    Chiaki.settings.psnNpssoToken = token;
                }
                KeyNavigation.priority: KeyNavigation.AfterItem
                KeyNavigation.up: pasteUrl
                KeyNavigation.down: openNpssoButton
                C.Button {
                    id: openNpssoButton
                    text: qsTr("Open NPSSO Page")
                    anchors {
                        left: parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: 10
                    }
                    KeyNavigation.priority: KeyNavigation.BeforeItem
                    onClicked: {
                        Chiaki.openNpssoPage()
                    }
                    KeyNavigation.left: npssoToken
                    KeyNavigation.up: npssoToken
                    Keys.onUpPressed: (event) => {
                        npssoToken.forceActiveFocus();
                        event.accepted = true;
                    }
                    lastInFocusChain: true
                }
            }

            Label {
                Layout.columnSpan: 2
                Layout.topMargin: 5
                text: qsTr("Required for Game Catalog and Game Library. Sign in first, then copy the full token from the page.")
                wrapMode: Text.Wrap
                font.pixelSize: 11
                opacity: 0.8
                color: Qt.rgba(255, 255, 255, 0.7)
            }
            }
        }

        ColumnLayout {
            id: accountForm
            anchors {
                top: parent.top
                horizontalCenter: parent.horizontalCenter
                topMargin: parent.height / 10
            }
            visible: false

            Label {
                id: formLabel
                Layout.alignment: Qt.AlignCenter
                Layout.bottomMargin: 50
                text: qsTr("This requires your privacy settings to allow anyone to find you in your search")
            }

            C.TextField {
                id: usernameField
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                Layout.preferredWidth: 400
                Layout.alignment: Qt.AlignCenter
                firstInFocusChain: true
                placeholderText: qsTr("Username")
                onAccepted: submitButton.clicked()
            }

            C.Button {
                id: submitButton
                Layout.preferredWidth: 400
                Layout.alignment: Qt.AlignCenter
                lastInFocusChain: true
                text: qsTr("Submit")
                onClicked: {
                    const username = usernameField.text.trim();
                    if (!username.length || !enabled)
                        return;
                    const request = new XMLHttpRequest();
                    request.onreadystatechange = function() {
                        if (request.readyState === XMLHttpRequest.DONE) {
                            const response = JSON.parse(request.response);
                            const accountId = response["encoded_id"];
                            if (accountId) {
                                dialog.callback(accountId);
                                dialog.close();
                            } else {
                                enabled = true;
                                formLabel.text = qsTr("Error: %1!").arg(response["error"]);
                            }
                        }
                    }
                    request.open("GET", "https://psn.flipscreen.games/search.php?username=%1".arg(encodeURIComponent(username)));
                    request.send();
                    enabled = false;
                }
            }
        }

        Connections {
            target: Chiaki

            function onPsnLoginAccountIdDone(accountId) {
                dialog.callback(accountId);
                submitting = false;
                dialog.close();
            }

            function onPsnLoginAccountIdError(error) {
                if(nativeLoginForm.visible)
                {
                    webView.visible = false;
                    nativeErrorLabel.text = error;
                    nativeErrorLabel.visible = true;
                    nativeErrorGrid.visible = true;
                }
                else
                {
                    errorHeader.visible = true;
                    errorLabel.text = error;
                    errorLabel.visible = true;
                    submitting = false;
                }
            }
        }
    }
}
