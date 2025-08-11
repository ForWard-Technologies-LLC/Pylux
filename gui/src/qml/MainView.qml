import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Effects

import org.streetpea.chiaking

Pane {
    padding: 0
    id: consolePane
    
    // Clean blue background
    CleanBlueBackground {
        anchors.fill: parent
        z: -2
    }
    
    StackView.onActivated: {
        // Set initial focus based on what's visible
        if (hostsView.count === 0) {
            // Focus will be handled by noConsolesDialog.onVisibleChanged
        } else {
            discoveryButton.forceActiveFocus(Qt.TabFocusReason);
        }
        
        if(!Chiaki.autoConnect && !root.initialAsk && !Chiaki.window.directStream)
        {
            root.initialAsk = true;
            if(Chiaki.settings.addSteamShortcutAsk && (typeof Chiaki.createSteamShortcut === "function"))
                root.showRemindDialog(qsTr("Official Steam artwork + controller layout"), qsTr("Would you like to either create a new non-Steam game for chiaki-ng\nor update an existing non-Steam game with the official artwork and controller layout?") + "\n\n" + qsTr("(Note: If you select no now and want to do this later, click the button or press R3 from the main menu.)"), false, () => root.showSteamShortcutDialog(true));
            else if(Chiaki.settings.remotePlayAsk)
            {
                if(!Chiaki.settings.psnRefreshToken || !Chiaki.settings.psnAuthToken || !Chiaki.settings.psnAuthTokenExpiry || !Chiaki.settings.psnAccountId)
                    root.showRemindDialog(qsTr("Remote Play via PSN"), qsTr("Would you like to connect to PSN?\nThis enables:\n- Automatic registration\n- Playing outside of your home network without port forwarding?") + "\n\n" + qsTr("(Note: If you select no now and want to do this later, go to the Config section of the settings.)"), true, () => root.showPSNTokenDialog(false));
                else
                    Chiaki.settings.remotePlayAsk = false;
            }
        }
    }
    
    Keys.onUpPressed: {
        if(hostsView.currentItem && hostsView.currentItem.visible)
        {
            let itemsPerRow = Math.floor(hostsView.width / hostsView.cellWidth);
            let newIndex = Math.max(0, hostsView.currentIndex - itemsPerRow);
            hostsView.currentIndex = newIndex;
            while(hostsView.currentItem && !hostsView.currentItem.visible && hostsView.currentIndex > 0)
            {
                hostsView.currentIndex = Math.max(0, hostsView.currentIndex - 1);
            }
        }
    }
    Keys.onDownPressed: {
        if(hostsView.currentItem && hostsView.currentItem.visible)
        {
            let itemsPerRow = Math.floor(hostsView.width / hostsView.cellWidth);
            let newIndex = Math.min(hostsView.count - 1, hostsView.currentIndex + itemsPerRow);
            hostsView.currentIndex = newIndex;
            while(hostsView.currentItem && !hostsView.currentItem.visible && hostsView.currentIndex < hostsView.count - 1)
            {
                hostsView.currentIndex = Math.min(hostsView.count - 1, hostsView.currentIndex + 1);
            }
        }
    }
    Keys.onLeftPressed: {
        if(hostsView.currentItem && hostsView.currentItem.visible)
        {
            hostsView.decrementCurrentIndex()
            while(hostsView.currentItem && !hostsView.currentItem.visible && hostsView.currentIndex > 0)
                hostsView.decrementCurrentIndex()
        }
    }
    Keys.onRightPressed: {
        if(hostsView.currentItem && hostsView.currentItem.visible)
        {
            hostsView.incrementCurrentIndex()
            while(hostsView.currentItem && !hostsView.currentItem.visible && hostsView.currentIndex < hostsView.count - 1)
                 hostsView.incrementCurrentIndex()
        }
    }
    Keys.onMenuPressed: settingsButton.clicked()
    Keys.onReturnPressed: if (hostsView.currentItem) hostsView.currentItem.connectToHost()
    Keys.onYesPressed: if (hostsView.currentItem) hostsView.currentItem.wakeUpHost()
    Keys.onNoPressed: if (hostsView.currentItem) hostsView.currentItem.deleteHost()
    Keys.onEscapePressed: root.showConfirmDialog(qsTr("Quit"), qsTr("Are you sure you want to quit?"), () => Qt.quit())
    Keys.onPressed: (event) => {
        if (event.modifiers)
            return;
        switch (event.key) {
        case Qt.Key_PageUp:
            if (hostsView.currentItem) hostsView.currentItem.setConsolePin();
            event.accepted = true;
            break;
        case Qt.Key_PageDown:
            if (Chiaki.settings.psnAuthToken) Chiaki.refreshPsnToken();
            event.accepted = true;
            break;
        case Qt.Key_F1:
            if (typeof Chiaki.createSteamShortcut === "function") root.showSteamShortcutDialog(false);
            event.accepted = true;
            break;
        case Qt.Key_F2:
            root.showManualHostDialog();
            event.accepted = true;
            break;
        }
    }

    // Futuristic Header
    Rectangle {
        id: headerBar
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
        }
        height: 100
        
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: Qt.rgba(0, 212/255, 255/255, 0.15) }
            GradientStop { position: 1.0; color: Qt.rgba(0, 212/255, 255/255, 0.05) }
        }
        
        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(10/255, 20/255, 38/255, 0.9)
        }
        
        // Glowing border effect
        Rectangle {
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            height: 2
            color: "#00d4ff"
            opacity: 0.7
            
            Rectangle {
                anchors.fill: parent
                color: "#00d4ff"
                layer.enabled: true
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blurMax: 16
                    blur: 0.8
                }
            }
        }

        RowLayout {
            anchors {
                fill: parent
                leftMargin: 25
                rightMargin: 25
                topMargin: 15
                bottomMargin: 15
            }
            spacing: 20

            // Logo and title section
            RowLayout {
                Layout.fillHeight: true
                spacing: 15
                
                Rectangle {
                    Layout.preferredWidth: 60
                    Layout.preferredHeight: 60
                    radius: 8
                    color: "#00d4ff"
                    
                    Text {
                        anchors.centerIn: parent
                        text: "PS"
                        font.pixelSize: 20
                        font.weight: Font.Bold
                        color: "#000000"
                    }
                    
                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: "transparent"
                        border.color: "#00d4ff"
                        border.width: 2
                        opacity: 0.5
                        
                        layer.enabled: true
                        layer.effect: MultiEffect {
                            blurEnabled: true
                            blurMax: 8
                            blur: 0.4
                        }
                    }
                }
                
                Column {
                    Layout.alignment: Qt.AlignVCenter
                    
                    Label {
                        text: "PSSTREAM"
                        font.pixelSize: 24
                        font.weight: Font.Bold
                        font.letterSpacing: 2
                        color: "#00d4ff"
                    }
                    Label {
                        text: "PlayStation Remote Play"
                        font.pixelSize: 12
                        font.weight: Font.Light
                        color: Qt.rgba(255, 255, 255, 0.7)
                        font.letterSpacing: 1
                    }
                }
            }

            Item { Layout.fillWidth: true }

            // Action buttons with futuristic styling
            RowLayout {
                Layout.fillHeight: true
                spacing: 15

                Button {
                    id: discoveryButton
                    Layout.preferredHeight: 50
                    Layout.preferredWidth: 50
                    flat: true
                    icon.source: "qrc:/icons/discover-" + (checked ? "" : "off-") + "24px.svg"
                    icon.width: 24
                    icon.height: 24
                    focusPolicy: Qt.StrongFocus
                    checkable: true
                    checked: Chiaki.discoveryEnabled
                    onToggled: Chiaki.discoveryEnabled = !Chiaki.discoveryEnabled
                    
                    // Keyboard navigation
                    KeyNavigation.right: manuallyAddHeaderButton
                    KeyNavigation.down: hostsView.count === 0 ? autoAddButton : hostsView
                    
                    background: Rectangle {
                        radius: 25
                        color: {
                            if (parent.activeFocus) return Qt.rgba(0, 212/255, 255/255, 0.4)
                            else if (parent.checked) return Qt.rgba(0, 212/255, 255/255, 0.3)
                            else return Qt.rgba(255, 255, 255, 0.1)
                        }
                        border.color: parent.activeFocus ? "#ffffff" : "#00d4ff"
                        border.width: parent.activeFocus ? 2 : 1
                        
                        Behavior on color { ColorAnimation { duration: 200 } }
                        Behavior on border.color { ColorAnimation { duration: 200 } }
                        Behavior on border.width { NumberAnimation { duration: 200 } }
                        
                        // Focus glow effect
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "transparent"
                            border.color: "#00d4ff"
                            border.width: 2
                            opacity: parent.parent.activeFocus ? 0.6 : 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                    }
                    
                    ToolTip.visible: hovered || activeFocus
                    ToolTip.text: qsTr("Console Discovery")
            }

            Button {
                    id: manuallyAddHeaderButton
                    Layout.preferredHeight: 45
                    Layout.preferredWidth: 160
                    text: qsTr("Manually Add")
                    font.pixelSize: 14
                    font.weight: Font.Medium
                    focusPolicy: Qt.StrongFocus
                    onClicked: root.showManualHostDialog()
                    
                    // Keyboard navigation
                    KeyNavigation.left: discoveryButton
                    KeyNavigation.right: settingsButton
                    KeyNavigation.down: hostsView.count === 0 ? autoAddButton : hostsView
                    
                    background: Rectangle {
                        radius: 8
                        color: parent.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.2) : Qt.rgba(0, 212/255, 255/255, 0.1)
                        border.color: parent.activeFocus ? "#ffffff" : "#00d4ff"
                        border.width: parent.activeFocus ? 2 : 1
                        
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "#00d4ff"
                            opacity: parent.parent.hovered ? 0.2 : 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                        
                        // Focus glow effect
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "transparent"
                            border.color: "#00d4ff"
                            border.width: 2
                            opacity: parent.parent.activeFocus ? 0.5 : 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                        
                        Behavior on color { ColorAnimation { duration: 200 } }
                        Behavior on border.color { ColorAnimation { duration: 200 } }
                        Behavior on border.width { NumberAnimation { duration: 200 } }
                    }
                    
                    contentItem: Text {
                        text: parent.text
                        font: parent.font
                        color: parent.activeFocus ? "#ffffff" : "#00d4ff"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
            }

            Button {
                    Layout.preferredHeight: 45
                    Layout.preferredWidth: 180
                    text: qsTr("Refresh PSN")
                    font.pixelSize: 14
                    font.weight: Font.Medium
                focusPolicy: Qt.NoFocus
                    onClicked: Chiaki.refreshPsnToken()
                    visible: Chiaki.settings.psnAuthToken
                    
                    background: Rectangle {
                        radius: 8
                        color: Qt.rgba(0, 212/255, 255/255, 0.1)
                        border.color: "#00d4ff"
                        border.width: 1
                        
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "#00d4ff"
                            opacity: parent.parent.hovered ? 0.2 : 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                    }
                    
                    contentItem: Text {
                        text: parent.text
                        font: parent.font
                        color: "#00d4ff"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
            }



            Button {
                id: settingsButton
                    Layout.preferredHeight: 50
                    Layout.preferredWidth: 50
                flat: true
                    icon.source: "qrc:/icons/settings-20px.svg"
                    icon.width: 24
                    icon.height: 24
                focusPolicy: Qt.StrongFocus
                onClicked: root.showSettingsDialog()
                
                // Keyboard navigation
                KeyNavigation.left: manuallyAddHeaderButton
                KeyNavigation.right: closeButton
                KeyNavigation.down: hostsView.count === 0 ? autoAddButton : hostsView
                    
                    background: Rectangle {
                        radius: 25
                        color: parent.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.2) : Qt.rgba(255, 255, 255, 0.1)
                        border.color: parent.activeFocus ? "#ffffff" : "#00d4ff"
                        border.width: parent.activeFocus ? 2 : 1
                        
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "#00d4ff"
                            opacity: parent.parent.hovered ? 0.3 : 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                        
                        // Focus glow effect
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "transparent"
                            border.color: "#00d4ff"
                            border.width: 2
                            opacity: parent.parent.activeFocus ? 0.6 : 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                        
                        Behavior on color { ColorAnimation { duration: 200 } }
                        Behavior on border.color { ColorAnimation { duration: 200 } }
                        Behavior on border.width { NumberAnimation { duration: 200 } }
                    }
                    
                    ToolTip.visible: hovered || activeFocus
                    ToolTip.text: qsTr("Settings")
                }

                Button {
                    id: closeButton
                    Layout.preferredHeight: 45
                    Layout.preferredWidth: 45
                    flat: true
                    text: "×"
                    font.pixelSize: 24
                    font.weight: Font.Bold
                    focusPolicy: Qt.StrongFocus
                    onClicked: Qt.quit()
                    
                    // Keyboard navigation
                    KeyNavigation.left: settingsButton
                    KeyNavigation.down: hostsView.count === 0 ? autoAddButton : hostsView
                    
                    background: Rectangle {
                        radius: 8
                        color: parent.activeFocus ? Qt.rgba(255, 100/255, 100/255, 0.2) : Qt.rgba(255, 100/255, 100/255, 0.1)
                        border.color: parent.activeFocus ? "#ffffff" : Qt.rgba(255, 100/255, 100/255, 0.5)
                        border.width: parent.activeFocus ? 2 : 1
                        
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: Qt.rgba(255, 100/255, 100/255, 0.3)
                            opacity: parent.parent.hovered ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                        
                        // Focus glow effect
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "transparent"
                            border.color: Qt.rgba(255, 100/255, 100/255, 0.8)
                            border.width: 2
                            opacity: parent.parent.activeFocus ? 0.6 : 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                        
                        Behavior on color { ColorAnimation { duration: 200 } }
                        Behavior on border.color { ColorAnimation { duration: 200 } }
                        Behavior on border.width { NumberAnimation { duration: 200 } }
                    }
                    
                    contentItem: Text {
                        text: parent.text
                        font: parent.font
                        color: parent.activeFocus ? "#ffffff" : Qt.rgba(255, 150/255, 150/255, 1)
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                    
                    ToolTip.visible: hovered || activeFocus
                    ToolTip.text: qsTr("Quit PSStream")
                }
            }
        }
    }

    // Console Cards Grid
    ScrollView {
        id: scrollView
        anchors {
            top: headerBar.bottom
            left: parent.left
            right: parent.right
            bottom: footerBar.top
            margins: 30
            topMargin: 20
        }
        
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        
        // Custom scrollbar styling
        ScrollBar.vertical: ScrollBar {
            width: 8
            policy: ScrollBar.AsNeeded
            
            background: Rectangle {
                color: Qt.rgba(255, 255, 255, 0.1)
                radius: 4
            }
            
            contentItem: Rectangle {
                radius: 4
                color: "#00d4ff"
                opacity: 0.7
            }
        }

        GridView {
            id: hostsView
            keyNavigationWraps: true
            cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 380)))
            cellHeight: 220
        model: Chiaki.hosts
            
        onCountChanged: {
            if(!hostsView.currentItem)
                hostsView.incrementCurrentIndex();
            if(!hostsView.currentItem)
                return;
            if(!hostsView.currentItem.visible)
            {
                for(var i = 0; i < hostsView.count; i++)
                {
                    hostsView.incrementCurrentIndex()
                    if(hostsView.currentItem.visible)
                    {
                        break;
                    }
                }
            }
        }
            
            delegate: Item {
            visible: modelData.display
                width: hostsView.cellWidth
                height: hostsView.cellHeight
                
                // Console Card
                Rectangle {
                    id: consoleCard
                    anchors {
                        fill: parent
                        margins: 15
                    }
                    radius: 12
                    color: Qt.rgba(0, 212/255, 255/255, GridView.isCurrentItem ? 0.15 : 0.05)
                    border.color: GridView.isCurrentItem ? "#00d4ff" : Qt.rgba(255, 255, 255, 0.1)
                    border.width: GridView.isCurrentItem ? 2 : 1
                    
                    Behavior on color { ColorAnimation { duration: 200 } }
                    Behavior on border.color { ColorAnimation { duration: 200 } }
                    
                    // Glow effect for current item
                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: "transparent"
                        border.color: "#00d4ff"
                        border.width: 2
                        opacity: GridView.isCurrentItem ? 0.5 : 0
                        visible: opacity > 0
                        
                        layer.enabled: GridView.isCurrentItem
                        layer.effect: MultiEffect {
                            blurEnabled: true
                            blurMax: 16
                            blur: 0.6
                        }
                        
                        Behavior on opacity { NumberAnimation { duration: 200 } }
                    }
                    
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            hostsView.currentIndex = index;
                            connectToHost();
                        }
                        
                        onEntered: {
                            consoleCard.color = Qt.rgba(0, 212/255, 255/255, 0.1);
                        }
                        onExited: {
                            if (!GridView.isCurrentItem) {
                                consoleCard.color = Qt.rgba(0, 212/255, 255/255, 0.05);
                            }
                        }
                    }

            function connectToHost() {
                if(modelData.discovered)
                    Chiaki.connectToHost(index, modelData.name);
                else
                    Chiaki.connectToHost(index);
            }

            function wakeUpHost() {
                if(!modelData.discovered && !modelData.duid)
                    Chiaki.wakeUpHost(index);
            }

            function deleteHost() {
                if (modelData.manual)
                    root.showConfirmDialog(qsTr("Delete Console"), qsTr("Are you sure you want to delete this console?"), () => {Chiaki.deleteHost(index)});
                        
                else if (modelData.discovered && !modelData.registered)
                    root.showConfirmDialog(qsTr("Hide Console"), qsTr("Are you sure you want to hide this console?") + "\n\n" + qsTr("Note: You can unhide from the Consoles section of the Settings under Hidden Consoles"), () => Chiaki.hideHost(modelData.mac, modelData.name));
            }

            function setConsolePin() {
                root.showConsolePinDialog(index);
            }

                    ColumnLayout {
                anchors {
                    fill: parent
                            margins: 20
                        }
                        spacing: 15
                        
                        // Console icon and status
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 15
                            
                            Rectangle {
                                Layout.preferredWidth: 80
                                Layout.preferredHeight: 80
                                radius: 8
                                color: Qt.rgba(0, 212/255, 255/255, 0.1)
                                border.color: Qt.rgba(0, 212/255, 255/255, 0.3)
                                border.width: 1

                Image {
                                    anchors.centerIn: parent
                                    width: 60
                                    height: 60
                    fillMode: Image.PreserveAspectFit
                    source: "image://svg/console-ps" + (modelData.ps5 ? "5" : "4") + (modelData.state == "standby" ? "#light_standby" : "#light_on")
                                    sourceSize: Qt.size(60, 60)
                                }
                            }
                            
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 5
                                
                                Label {
                                    Layout.fillWidth: true
                                    text: modelData.name || qsTr("Unknown Console")
                                    font.pixelSize: 18
                                    font.weight: Font.Bold
                                    color: "#ffffff"
                                    elide: Text.ElideRight
                }

                Label {
                                    Layout.fillWidth: true
                    text: {
                                        let status = "";
                                        if (modelData.duid) {
                                            status = modelData.discovered ? qsTr("Auto Registration") : qsTr("PSN Remote");
                                        } else {
                                            status = modelData.discovered ? qsTr("Discovered") : qsTr("Manual");
                                        }
                                        if (modelData.registered) status += " • " + qsTr("Registered");
                                        return status;
                                    }
                                    font.pixelSize: 12
                                    color: "#00d4ff"
                                    elide: Text.ElideRight
                                }
                                
                                Label {
                                    Layout.fillWidth: true
                                    text: qsTr("State: %1").arg(modelData.state)
                                    font.pixelSize: 11
                                    color: Qt.rgba(255, 255, 255, 0.7)
                                    elide: Text.ElideRight
                                }
                            }
                        }
                        
                        // Console details
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 60
                            radius: 6
                            color: Qt.rgba(0, 0, 0, 0.2)
                            
                            ColumnLayout {
                                anchors {
                                    fill: parent
                                    margins: 10
                                }
                                spacing: 3
                                
                                Label {
                                    Layout.fillWidth: true
                                    text: modelData.address ? qsTr("IP: %1").arg(Chiaki.settings.streamerMode ? "hidden" : modelData.address) : ""
                                    font.pixelSize: 10
                                    color: Qt.rgba(255, 255, 255, 0.6)
                                    elide: Text.ElideRight
                                }
                                
                                Label {
                                    Layout.fillWidth: true
                                    text: modelData.app ? qsTr("App: %1").arg(modelData.app) : ""
                                    font.pixelSize: 10
                                    color: Qt.rgba(255, 255, 255, 0.6)
                                    elide: Text.ElideRight
                }

                Label {
                                    Layout.fillWidth: true
                                    text: modelData.titleId ? qsTr("Title: %1").arg(modelData.titleId) : ""
                                    font.pixelSize: 10
                                    color: Qt.rgba(255, 255, 255, 0.6)
                                    elide: Text.ElideRight
                                }
                            }
                        }
                        
                        // Action buttons row
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                    Button {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 30
                        text: modelData.manual ? qsTr("Delete") : qsTr("Hide")
                                font.pixelSize: 10
                                visible: modelData.manual || (modelData.discovered && !modelData.registered)
                        focusPolicy: Qt.NoFocus
                                onClicked: consoleCard.deleteHost()
                                
                                background: Rectangle {
                                    radius: 4
                                    color: Qt.rgba(255, 100/255, 100/255, 0.1)
                                    border.color: Qt.rgba(255, 100/255, 100/255, 0.5)
                                    border.width: 1
                                }
                                
                                contentItem: Text {
                                    text: parent.text
                                    font: parent.font
                                    color: Qt.rgba(255, 150/255, 150/255, 1)
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Button {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 30
                                text: qsTr("Wake")
                                font.pixelSize: 10
                        visible: modelData.registered && !modelData.duid && !modelData.discovered
                        focusPolicy: Qt.NoFocus
                                onClicked: consoleCard.wakeUpHost()
                                
                                background: Rectangle {
                                    radius: 4
                                    color: Qt.rgba(255, 200/255, 0, 0.1)
                                    border.color: Qt.rgba(255, 200/255, 0, 0.5)
                                    border.width: 1
                                }
                                
                                contentItem: Text {
                                    text: parent.text
                                    font: parent.font
                                    color: Qt.rgba(255, 200/255, 0, 1)
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Button {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 30
                                text: qsTr("Pin")
                                font.pixelSize: 10
                        visible: modelData.registered
                        focusPolicy: Qt.NoFocus
                                onClicked: consoleCard.setConsolePin()
                                
                                background: Rectangle {
                                    radius: 4
                                    color: Qt.rgba(0, 212/255, 255/255, 0.1)
                                    border.color: "#00d4ff"
                                    border.width: 1
                                }
                                
                                contentItem: Text {
                                    text: parent.text
                                    font: parent.font
                                    color: "#00d4ff"
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }
                        }
                    }
                } 
            } 
        }
    }     

    // Footer bar
    Rectangle {
        id: footerBar
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        height: 50
        color: Qt.rgba(10/255, 20/255, 38/255, 0.9)
        
        Rectangle {
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
            }
            height: 1
            color: Qt.rgba(0, 212/255, 255/255, 0.3)
        }
        
        RowLayout {
            anchors {
                fill: parent
                leftMargin: 30
                rightMargin: 30
    }

    Label {
                text: Qt.application.version
                font.pixelSize: 12
                color: Qt.rgba(255, 255, 255, 0.5)
            }
            
            Item { Layout.fillWidth: true }
            
            Label {
                text: qsTr("Use ↑↓ to navigate • Enter to connect • Menu for settings")
                font.pixelSize: 11
                color: Qt.rgba(255, 255, 255, 0.5)
            }
        }
    }

    // No consoles state
    Rectangle {
        id: noConsolesDialog
        anchors.centerIn: parent
        width: 400
        height: 300
        radius: 12
        color: Qt.rgba(10/255, 15/255, 26/255, 0.9)
        border.color: Qt.rgba(0, 212/255, 255/255, 0.3)
        border.width: 1
        visible: hostsView.count === 0
        
        // Auto-focus the Auto Add button when dialog becomes visible
        onVisibleChanged: {
            if (visible) {
                autoAddButton.forceActiveFocus(Qt.TabFocusReason);
            }
        }
        
        ColumnLayout {
            anchors.centerIn: parent
            spacing: 20
            
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 80
                Layout.preferredHeight: 80
                radius: 12
                color: Qt.rgba(0, 212/255, 255/255, 0.1)
                border.color: "#00d4ff"
                border.width: 2
                opacity: 0.5
                
                Text {
                    anchors.centerIn: parent
                    text: "PS"
                    font.pixelSize: 28
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
                        blurMax: 12
                        blur: 0.6
                    }
                }
            }
            
            Label {
                Layout.alignment: Qt.AlignHCenter
                text: qsTr("No Consoles Found")
                font.pixelSize: 24
                font.weight: Font.Bold
                color: "#00d4ff"
            }
            
            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 350
                text: qsTr("Enable discovery or add a console manually to get started with PSStream")
                font.pixelSize: 14
                color: Qt.rgba(255, 255, 255, 0.7)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
            
            // Button row for console addition options
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 20
                
                // Manual Add Console Button
                Button {
                    id: manualAddButton
                    Layout.preferredWidth: 160
                    Layout.preferredHeight: 40
                    text: qsTr("Manually Add")
                    font.pixelSize: 14
                    font.weight: Font.Medium
                    onClicked: root.showManualHostDialog()
                    
                    // Keyboard navigation
                    KeyNavigation.right: autoAddButton
                    KeyNavigation.up: discoveryButton
                    
                    background: Rectangle {
                        radius: 8
                        color: parent.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.2) : Qt.rgba(0, 212/255, 255/255, 0.1)
                        border.color: parent.activeFocus ? "#ffffff" : "#00d4ff"
                        border.width: parent.activeFocus ? 2 : 1
                        
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "#00d4ff"
                            opacity: parent.parent.hovered ? 0.2 : 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                        
                        // Focus glow effect
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "transparent"
                            border.color: "#00d4ff"
                            border.width: 2
                            opacity: parent.parent.activeFocus ? 0.5 : 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                    }
                    
                    contentItem: Text {
                        text: parent.text
                        font: parent.font
                        color: parent.activeFocus ? "#ffffff" : "#00d4ff"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                }
                
                // Auto Add Console Button (PSN Login) - DEFAULT SELECTED
                Button {
                    id: autoAddButton
                    Layout.preferredWidth: 160
                    Layout.preferredHeight: 40
                    text: qsTr("Auto Add")
                    font.pixelSize: 14
                    font.weight: Font.Medium
                    onClicked: root.showPSNTokenDialog("", false)
                    
                    // Keyboard navigation
                    KeyNavigation.left: manualAddButton
                    KeyNavigation.up: manuallyAddHeaderButton
                    
                    // Set as default focus when dialog becomes visible
                    Component.onCompleted: {
                        if (parent.parent.parent.visible) {
                            forceActiveFocus(Qt.TabFocusReason);
                        }
                    }
                    
                    background: Rectangle {
                        radius: 8
                        color: parent.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.3) : Qt.rgba(0, 212/255, 255/255, 0.15)
                        border.color: parent.activeFocus ? "#ffffff" : "#00d4ff"
                        border.width: parent.activeFocus ? 3 : 2
                        
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "#00d4ff"
                            opacity: parent.parent.hovered ? 0.3 : 0.1
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                        
                        // Focus glow effect for default button
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "transparent"
                            border.color: "#00d4ff"
                            border.width: 3
                            opacity: parent.parent.activeFocus ? 0.7 : 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                    }
                    
                    contentItem: Text {
                        text: parent.text
                        font: parent.font
                        color: parent.activeFocus ? "#ffffff" : "#00d4ff"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                }
            }
        }
    }
}