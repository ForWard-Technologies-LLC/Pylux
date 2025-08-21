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
    title: {
        if(expired)
            qsTr("Credentials Expired: Refresh PSN Remote Connection")
        else
            qsTr("Setup Automatic PSN Remote Connection")
    }
    buttonText: qsTr("Setup")
    buttonEnabled: url.text.trim()
    buttonVisible: false
    onAccepted: {
        logDialog.open()
        Chiaki.initPsnAuth(url.text.trim(), function(msg, ok, done) {
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
        nativeTokenForm.visible = true;
        nativeTokenForm.forceActiveFocus(Qt.TabFocusReason);
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
                            nativeTokenForm.visible = false;
                            psnTokenToolbar.visible = false;
                            nativeErrorGrid.visible = false;
                            webView.visible = false;
                            linkgrid.visible = true;
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
                    try {
                        web = Qt.createQmlObject("
                        import QtWebEngine
                        import QtQuick.Controls
                        import org.streetpea.chiaking
                        WebEngineView {
                            profile {
                                offTheRecord: false
                                storageName: 'psn-token'
                                onClearHttpCacheCompleted: {
                                    if(dialog.closing)
                                        root.closeDialog();
                                    else
                                        webView.web.reload();
                                }
                            }
                            settings {
                                // Load larger touch icons
                                touchIconsEnabled: true
                                localContentCanAccessRemoteUrls: true
                            }

                            onContextMenuRequested: (request) => request.accepted = true;
                            onNavigationRequested: (request) => {
                                if (Chiaki.checkPsnRedirectURL(request.url)) {
                                    logDialog.open()
                                    Chiaki.initPsnAuth(request.url, function(msg, ok, done) {
                                        if (!done)
                                            logArea.text += msg + '\n';
                                        else
                                        {
                                            logArea.text += msg + '\n';
                                            logDialog.standardButtons = Dialog.Close;
                                        }
                                    });
                                    request.reject();
                                }
                                else
                                    request.accept();
                            }
                            onCertificateError: console.error(error.description);
                        }", webView, "webView");
                        Chiaki.setWebEngineHints(web.profile);
                        web.url = Chiaki.psnLoginUrl();
                        web.anchors.fill = webView;
                    } catch (error) {
                        console.error('Create webengine view failed with error:' + error);
                        extBrowserButton.clicked();
                    }
                }
            }
        }
        GridLayout {
            id: linkgrid
            visible: false
            anchors {
                top: parent.top
                horizontalCenter: parent.horizontalCenter
                topMargin: 50
            }
            columns: 2
            rowSpacing: 10
            columnSpacing: 20

            Label {
                text: qsTr("Open Web Browser with copied URL")
                visible: psnurl
            }

            TextField {
                id: openurl
                text: psnurl
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
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

            C.TextField {
                id: url
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                Layout.preferredWidth: 400
                KeyNavigation.up: {
                    if(psnurl)
                        copyUrl
                    else
                        url
                }
                KeyNavigation.down: url
                KeyNavigation.right: pasteUrl
                
                // Allow navigation to header button
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Up && readOnly) {
                        // Navigate to header button when at top
                        let headerButton = dialog.headerItem.children[dialog.headerItem.children.length - 1];
                        if (headerButton && headerButton.visible) {
                            headerButton.forceActiveFocus(Qt.TabFocusReason);
                            event.accepted = true;
                        }
                    }
                }
                C.Button {
                    id: pasteUrl
                    text: qsTr("Click to Paste URL")
                    anchors {
                        left: parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: 10
                    }
                    onClicked: url.paste()
                    KeyNavigation.priority: KeyNavigation.BeforeItem
                    KeyNavigation.left: url
                    KeyNavigation.up: {
                        if(psnurl)
                            copyUrl
                        else
                            pasteUrl
                    }
                    KeyNavigation.down: pasteUrl
                    
                    // Allow navigation to header button
                    Keys.onPressed: (event) => {
                        if (event.key === Qt.Key_Up) {
                            // Navigate to header button when at top
                            let headerButton = dialog.headerItem.children[dialog.headerItem.children.length - 1];
                            if (headerButton && headerButton.visible) {
                                headerButton.forceActiveFocus(Qt.TabFocusReason);
                                event.accepted = true;
                            }
                        }
                    }
                }
            }
        }

        Item {
            Dialog {
                id: logDialog
                parent: Overlay.overlay
                x: Math.round((root.width - width) / 2)
                y: Math.round((root.height - height) / 2)
                title: qsTr("Create PSN Automatic Remote Connection Token")
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