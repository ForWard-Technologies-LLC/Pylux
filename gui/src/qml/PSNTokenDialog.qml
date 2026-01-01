import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

import "controls" as C

DialogView {
    id: dialog
    property var psnurl
    property var expired
    property bool closing: false
    property bool hasNpssoData: false
    
    function extractNpssoFromText(inputText) {
        if (!inputText || inputText.trim().length === 0) {
            return null;
        }
        
        let trimmed = inputText.trim();
        
        // Try to parse as JSON
        if (trimmed.startsWith("{") && trimmed.indexOf("npsso") >= 0) {
            try {
                let json = JSON.parse(trimmed);
                if (json.npsso && json.npsso.length > 0) {
                    return json.npsso.trim();
                }
            } catch (e) {
                // Not valid JSON, try as plain token
            }
        }
        
        // Check if it looks like a valid npsso token (alphanumeric, typically long)
        if (trimmed.length >= 40 && /^[A-Za-z0-9]+$/.test(trimmed)) {
            return trimmed;
        }
        
        return null;
    }
    title: {
        if(expired)
            qsTr("Credentials Expired: Refresh PSN Authentication")
        else
            qsTr("PSN Login")
    }
    buttonText: qsTr("Connect")
    buttonEnabled: hasNpssoData
    buttonVisible: false
    onAccepted: {
        let npssoTokenValue = npssoToken.text.trim();
        
        if (npssoTokenValue.length === 0) {
            logDialog.open()
            logArea.text = qsTr("[E] NPSSO token is required. Please complete the steps above to obtain your npsso token.");
            logDialog.standardButtons = Dialog.Close;
            return;
        }
        
        logDialog.open()
        logArea.text = qsTr("[I] Starting PSN authentication with npsso token...\n");
        Chiaki.initPsnAuthV3(npssoTokenValue, function(msg, ok, done) {
            if(ok)
                Chiaki.settings.remotePlayAsk = false;
            if (!done)
                logArea.text += msg + "\n";
            else
            {
                logArea.text += msg + "\n";
                logDialog.standardButtons = Dialog.Close;
            }
        });
    }
    StackView.onActivated: {
        Chiaki.settings.remotePlayAsk = true;
        if (linkgridScroll.visible) {
            Qt.callLater(() => {
                if (step1Button) {
                    step1Button.forceActiveFocus(Qt.TabFocusReason);
                }
            });
        } else {
            nativeTokenForm.visible = true;
            nativeTokenForm.forceActiveFocus(Qt.TabFocusReason);
        }
        // Set up navigation from header button to paste button
        Qt.callLater(() => {
            if (dialog.headerButton && pasteButton) {
                dialog.headerButton.KeyNavigation.down = pasteButton;
            }
        });
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
            id: nativeTokenForm
            visible: false
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
            Rectangle {
                id: psnTokenToolbar
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
                        font.pixelSize: 14
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
                        font.pixelSize: 14
                        font.weight: Font.Medium
                        focusPolicy: Qt.NoFocus
                        onClicked: {
                            nativeTokenForm.visible = false;
                            psnTokenToolbar.visible = false;
                            nativeErrorGrid.visible = false;
                            webView.visible = false;
                            linkgridScroll.visible = true;
                            dialog.buttonVisible = true;
                            // Open login page in external browser
                            let loginUrl = Chiaki.psnLoginUrl();
                            if (loginUrl) {
                                Qt.openUrlExternally(loginUrl);
                                psnurl = loginUrl.toString();
                                if(openurl) {
                                    openurl.text = psnurl;
                                    openurl.selectAll();
                                    openurl.copy();
                                }
                            }
                            // Set up navigation from header button to npsso field
                            Qt.callLater(() => {
                                if (dialog.headerButton && pasteButton) {
                                    dialog.headerButton.KeyNavigation.down = pasteButton;
                                }
                            });
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
                    top: psnTokenToolbar.bottom
                    left: parent.left
                    right: parent.right
                    topMargin: 50
                }
                columns: 2
                rowSpacing: 10
                columnSpacing: 20
                Label {
                    id: nativeErrorHeader
                    text: "Retrieving PSN account ID failed with error: "
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
                    bottom: psnTokenToolbar.top
                    left: parent.left
                    right: parent.right
                    leftMargin: 10
                    rightMargin: 10
                }
                property bool started: false
                Component.onCompleted: {
                    // Always use external browser - don't create WebEngine view
                    nativeTokenForm.visible = false;
                    psnTokenToolbar.visible = false;
                    nativeErrorGrid.visible = false;
                    webView.visible = false;
                    linkgridScroll.visible = true;
                    dialog.buttonVisible = true;
                }
            }
        }
        ScrollView {
            id: linkgridScroll
            visible: false
            anchors.fill: parent
            anchors.margins: 0
            clip: true
            ScrollBar.vertical.policy: ScrollBar.AsNeeded
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            contentWidth: availableWidth
            onVisibleChanged: {
                if (visible) {
                    Qt.callLater(() => {
                        if (pasteButton) {
                            pasteButton.forceActiveFocus(Qt.TabFocusReason);
                        }
                    });
                }
            }
            
            ColumnLayout {
                id: linkgrid
                width: linkgridScroll.availableWidth
                height: linkgridScroll.availableHeight
                spacing: 12

                // Warning banner at top
                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: 10
                    Layout.rightMargin: 10
                    Layout.topMargin: 20
                    Layout.preferredHeight: blankPageNote.implicitHeight + 16
                    color: Qt.rgba(255, 193/255, 7/255, 0.15)
                    radius: 6
                    border.color: Qt.rgba(255, 193/255, 7/255, 0.4)
                    border.width: 1

                    Label {
                        id: blankPageNote
                        anchors.fill: parent
                        anchors.margins: 14
                        text: qsTr("⚠️ After logging in, Remote Play will redirect to a blank page - that's fine! Return here once that happens.")
                        wrapMode: Text.Wrap
                        font.pixelSize: 18
                        color: Qt.rgba(255, 235/255, 59/255, 0.95)
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                // Three columns layout
                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.leftMargin: 10
                    Layout.rightMargin: 10
                    spacing: 16

                    // Step 1: Open Login Page
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.minimumWidth: 0
                        Layout.preferredWidth: 0
                        color: Qt.rgba(0, 0, 0, 0.3)
                        radius: 10
                        border.color: Qt.rgba(0, 212/255, 255/255, 0.4)
                        border.width: 1

                        ColumnLayout {
                            id: step1Content
                            anchors.fill: parent
                            anchors.margins: 16
                            spacing: 14

                            Label {
                                text: qsTr("Step 1: Open Login Page")
                                font.pixelSize: 26
                                font.weight: Font.Bold
                                color: "#00d4ff"
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Label {
                                text: qsTr("Click the button below to open the PSN login page in your external browser.")
                                wrapMode: Text.Wrap
                                Layout.fillWidth: true
                                font.pixelSize: 19
                                color: Qt.rgba(255, 255, 255, 0.95)
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 8
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                            }

                            C.Button {
                                id: step1Button
                                text: qsTr("Open Login Page")
                                onClicked: {
                                    let loginUrl = Chiaki.psnLoginUrl();
                                    if (loginUrl) {
                                        Qt.openUrlExternally(loginUrl);
                                        if(openurl) {
                                            openurl.text = loginUrl.toString();
                                            openurl.selectAll();
                                            openurl.copy();
                                        }
                                    }
                                }
                                Layout.fillWidth: true
                                Layout.preferredHeight: 44
                                Layout.maximumWidth: 300
                                Layout.alignment: Qt.AlignHCenter
                                font.pixelSize: 17
                                font.weight: Font.Medium
                                KeyNavigation.right: openNpssoPageButton
                                Keys.onLeftPressed: (event) => {
                                    event.accepted = false; // Allow wrapping to last column
                                }
                            }

                            TextField {
                                id: openurl
                                text: psnurl
                                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                                visible: false
                                Layout.fillWidth: true
                            }
                        }
                    }

                    // Step 2: Open NPSSO Page
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.minimumWidth: 0
                        Layout.preferredWidth: 0
                        color: Qt.rgba(0, 0, 0, 0.3)
                        radius: 10
                        border.color: Qt.rgba(0, 212/255, 255/255, 0.4)
                        border.width: 1

                        ColumnLayout {
                            id: step2Content
                            anchors.fill: parent
                            anchors.margins: 16
                            spacing: 14

                            Label {
                                text: qsTr("Step 2: Open NPSSO Page")
                                font.pixelSize: 26
                                font.weight: Font.Bold
                                color: "#00d4ff"
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Label {
                                text: qsTr("After logging in, click below to open the NPSSO page. Once redirected, copy the npsso value shown on that page.")
                                wrapMode: Text.Wrap
                                Layout.fillWidth: true
                                font.pixelSize: 19
                                color: Qt.rgba(255, 255, 255, 0.95)
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                            }

                            C.Button {
                                id: openNpssoPageButton
                                text: qsTr("Open NPSSO Page")
                                onClicked: {
                                    Chiaki.openNpssoPage()
                                }
                                Layout.fillWidth: true
                                Layout.preferredHeight: 44
                                Layout.maximumWidth: 300
                                Layout.alignment: Qt.AlignHCenter
                                font.pixelSize: 17
                                font.weight: Font.Medium
                                KeyNavigation.left: step1Button
                                KeyNavigation.right: pasteButton
                                KeyNavigation.down: pasteButton
                            }
                        }
                    }

                    // Step 3: Paste NPSSO Token
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.minimumWidth: 0
                        Layout.preferredWidth: 0
                        color: Qt.rgba(0, 0, 0, 0.3)
                        radius: 10
                        border.color: Qt.rgba(0, 212/255, 255/255, 0.4)
                        border.width: 1

                        ColumnLayout {
                            id: step3Content
                            anchors.fill: parent
                            anchors.margins: 16
                            spacing: 14

                            Label {
                                text: qsTr("Step 3: Paste NPSSO Token")
                                font.pixelSize: 26
                                font.weight: Font.Bold
                                color: "#00d4ff"
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Label {
                                text: qsTr("Copy the npsso token from the NPSSO page and paste it below.")
                                wrapMode: Text.Wrap
                                Layout.fillWidth: true
                                font.pixelSize: 19
                                color: Qt.rgba(255, 255, 255, 0.95)
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                            }

                            C.TextField {
                                id: npssoToken
                                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                                focusPolicy: Qt.NoFocus
                                Layout.fillWidth: true
                                Layout.preferredHeight: 44
                                Layout.maximumWidth: 300
                                Layout.alignment: Qt.AlignHCenter
                                placeholderText: qsTr("Paste npsso token here")
                                font.pixelSize: 17
                                Component.onCompleted: {
                                    text = Chiaki.settings.psnNpssoToken;
                                    dialog.hasNpssoData = text.trim().length > 0;
                                }
                                onTextChanged: {
                                    // Parse input: extract token from JSON format or use as-is
                                    let inputText = text.trim();
                                    let extractedToken = dialog.extractNpssoFromText(inputText);
                                    let token = extractedToken || inputText;
                                    
                                    Chiaki.settings.psnNpssoToken = token;
                                    dialog.hasNpssoData = inputText.length > 0;
                                }
                            }

                            C.Button {
                                id: pasteButton
                                text: qsTr("Paste from Clipboard")
                                onClicked: {
                                    let clipboardText = Chiaki.getClipboardText();
                                    if (clipboardText) {
                                        // Extract token from clipboard (handles both JSON and plain formats)
                                        let extractedToken = dialog.extractNpssoFromText(clipboardText);
                                        
                                        if (extractedToken && extractedToken.length > 0) {
                                            // Set the extracted token in the text field
                                            npssoToken.text = extractedToken;
                                            
                                            // Automatically trigger connect button if valid token detected
                                            Qt.callLater(() => {
                                                if (dialog.headerButton && dialog.headerButton.enabled) {
                                                    dialog.accepted();
                                                }
                                            });
                                        } else {
                                            // If no valid token found, just paste the raw text
                                            npssoToken.text = clipboardText;
                                        }
                                    }
                                }
                                Layout.fillWidth: true
                                Layout.preferredHeight: 44
                                Layout.maximumWidth: 300
                                Layout.alignment: Qt.AlignHCenter
                                font.pixelSize: 17
                                font.weight: Font.Medium
                                KeyNavigation.left: openNpssoPageButton
                                KeyNavigation.right: step1Button
                                Keys.onReturnPressed: clicked()
                                Keys.onEnterPressed: clicked()
                            }
                        }
                    }
                }

                // Help text at bottom
                Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: 10
                    Layout.rightMargin: 10
                    Layout.bottomMargin: 10
                    Layout.topMargin: 12
                    text: qsTr("💡 Tip: You can also get the token from browser cookies: Application/Storage → Cookies → ca.account.sony.com → npsso")
                    wrapMode: Text.Wrap
                    font.pixelSize: 15
                    opacity: 0.75
                    color: Qt.rgba(200, 200, 255, 0.7)
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }

        Item {
            Dialog {
                id: logDialog
                parent: Overlay.overlay
                x: Math.round((root.width - width) / 2)
                y: Math.round((root.height - height) / 2)
                title: qsTr("PSN Authentication")
                modal: true
                closePolicy: Popup.NoAutoClose
                standardButtons: Dialog.Cancel
                Material.roundedScale: Material.MediumScale
                onOpened: logArea.forceActiveFocus(Qt.TabFocusReason)
                onClosed: root.showMainView();

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
    }
}