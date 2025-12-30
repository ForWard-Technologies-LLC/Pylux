import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Effects

import org.streetpea.chiaking

import "controls" as C

Pane {
    padding: 0
    id: consolePane
    focus: true
    activeFocusOnTab: true
    
    // Clean blue background
    CleanBlueBackground {
        anchors.fill: parent
        z: -2
    }
    
    StackView.onActivated: {
        // Only set focus if MainView is actually visible (not when settings/other dialogs are open)
        // Set contextual focus based on current state
        Qt.callLater(() => {
            // Check if we're actually the active view in the stack
            if (StackView.status !== StackView.Active)
                return;
            
            // Additional check: only set focus if we're the only item in the stack
            // This prevents stealing focus when dialogs/settings are open on top of MainView
            if (StackView.view && StackView.view.depth > 1)
                return;
            
            if (hostsView.count > 0) {
                // Has consoles - focus first console
                hostsView.currentIndex = 0;
                hostsView.selectedIndex = 0;
                hostsView.forceActiveFocus(Qt.TabFocusReason);
            } else {
                // No consoles - focus most relevant dialog button
                if (addManuallyButton.visible) {
                    addManuallyButton.forceActiveFocus(Qt.TabFocusReason);
                } else if (enableLocalDiscoveryButton.visible) {
                    enableLocalDiscoveryButton.forceActiveFocus(Qt.TabFocusReason);
                } else {
                    // Fallback to floating discovery button or tab bar
                    if (floatingDiscoveryButton.visible) {
                        floatingDiscoveryButton.forceActiveFocus(Qt.TabFocusReason);
                    } else if (mainTabBar) {
                        mainTabBar.itemAt(0).forceActiveFocus(Qt.TabFocusReason);
                    }
                }
            }
        })
        
        // Show setup guide on first launch
        if (!Chiaki.settings.setupGuideShown && !Chiaki.autoConnect && !Chiaki.window.directStream) {
            Qt.callLater(() => {
                root.showConsoleSetupWalkthrough();
                Chiaki.settings.setupGuideShown = true;
            });
        }
        
        if(!Chiaki.autoConnect && !root.initialAsk && !Chiaki.window.directStream)
        {
            root.initialAsk = true;
            // Commented out: Steam shortcut and controller layout prompt
            // This dialog would prompt to create/update a Steam shortcut with official artwork
            // and set the Steam Deck controller to use workshop layout ID 3049833406
            // if(Chiaki.settings.addSteamShortcutAsk && (typeof Chiaki.createSteamShortcut === "function"))
            //     root.showRemindDialog(qsTr("Official Steam artwork + controller layout"), qsTr("Would you like to either create a new non-Steam game for chiaki-ng\nor update an existing non-Steam game with the official artwork and controller layout?") + "\n\n" + qsTr("(Note: If you select no now and want to do this later, click the button or press R3 from the main menu.)"), false, () => root.showSteamShortcutDialog(true));
            
            // Commented out: Remote Play via PSN prompt
            // This dialog would prompt to connect to PSN for automatic registration and remote play
            // else if(Chiaki.settings.remotePlayAsk)
            // {
            //     if(!Chiaki.settings.psnRefreshToken || !Chiaki.settings.psnAuthToken || !Chiaki.settings.psnAuthTokenExpiry || !Chiaki.settings.psnAccountId)
            //         root.showRemindDialog(qsTr("Remote Play via PSN"), qsTr("Would you like to connect to PSN?\nThis enables:\n- Automatic registration\n- Playing outside of your home network without port forwarding?") + "\n\n" + qsTr("(Note: If you select no now and want to do this later, go to the Config section of the settings.)"), true, () => root.showPSNTokenDialog(false));
            //     else
            //         Chiaki.settings.remotePlayAsk = false;
            // }
        }
    }
    




    Keys.onMenuPressed: settingsButton.clicked()
    Keys.onReturnPressed: {
        // Only handle console connection if hostsView has focus
        if (hostsView.activeFocus && hostsView.currentItem) {
            hostsView.currentItem.connectToHost();
        } else {
            // Let the focused element handle the key
            event.accepted = false;
        }
    }
    // Y and N keys are now handled by the GridView directly
    Keys.onEscapePressed: root.showConfirmDialog(qsTr("Quit"), qsTr("Are you sure you want to quit?"), () => Qt.quit(), null, true)
    Keys.onPressed: (event) => {
        if (event.modifiers)
            return;
        switch (event.key) {
        case Qt.Key_PageUp:
            // L1 button - switch tabs or handle console pin
            if (mainTabBar.currentIndex > 0) {
                mainTabBar.currentIndex = 0;
                event.accepted = true;
            } else if (hostsView.activeFocus && hostsView.currentItem) {
                hostsView.currentItem.setConsolePin();
                event.accepted = true;
            }
            break;
        case Qt.Key_PageDown:
            // R1 button - switch tabs or refresh PSN
            if (mainTabBar.currentIndex < mainTabBar.count - 1) {
                mainTabBar.currentIndex = mainTabBar.count - 1;
                event.accepted = true;
            } else if (Chiaki.settings.psnAuthToken) {
                Chiaki.refreshPsnToken();
                event.accepted = true;
            } else {
                root.showPSNTokenDialog("", false);
                event.accepted = true;
            }
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
            color: "#50d4ff"
            opacity: 0.7
            
            Rectangle {
                anchors.fill: parent
                color: "#50d4ff"
                layer.enabled: true
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blurMax: 16
                    blur: 0.8
                }
            }
        }

        // Logo and title section (left side)
        RowLayout {
            anchors {
                left: parent.left
                top: parent.top
                bottom: parent.bottom
                leftMargin: 25
                topMargin: 15
                bottomMargin: 15
            }
            spacing: 15
            
            Image {
                Layout.preferredWidth: 60
                Layout.preferredHeight: 60
                source: "qrc:icons/chiaking.png"
                fillMode: Image.PreserveAspectFit
                smooth: true
                antialiasing: true
                mipmap: true
                sourceSize.width: 120
                sourceSize.height: 120
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
                    text: "Remote Play"
                    font.pixelSize: 12
                    font.weight: Font.Light
                    color: Qt.rgba(255, 255, 255, 0.7)
                    font.letterSpacing: 1
                }
            }
        }

        // Tab bar - centered relative to viewport to align with console cards
        // Account for ScrollView margins (30px each side) that affect visual centering
        TabBar {
            id: mainTabBar
            anchors {
                verticalCenter: parent.verticalCenter
            }
            // Center relative to the content area (viewport minus ScrollView margins)
            // ScrollView has margins: 30, so content area is narrower
            x: (consolePane.width - width) / 2 - 15
            background: Rectangle { color: "transparent" }
            
            // Load saved tab on startup
            Component.onCompleted: {
                let savedTab = Chiaki.settings.lastSelectedMainTab;
                if (savedTab >= 0 && savedTab < count) {
                    currentIndex = savedTab;
                }
            }
            
            // Save tab when it changes
            onCurrentIndexChanged: {
                Chiaki.settings.lastSelectedMainTab = currentIndex;
            }

            TabButton {
                text: qsTr("Remote Play")
                width: implicitWidth + 24
                font.pixelSize: 15
                font.weight: Font.Medium
                focusPolicy: Qt.StrongFocus
                
                // Keyboard navigation
                KeyNavigation.left: closeButton
                KeyNavigation.right: mainTabBar.itemAt(1) // Cloud Play tab
                Keys.onDownPressed: (event) => {
                    console.log("[Remote Play Tab] Down pressed, currentIndex:", mainTabBar.currentIndex, "cloudPlayLoader.active:", cloudPlayLoader.active);
                    event.accepted = true;
                    if (mainTabBar.currentIndex === 1 && cloudPlayLoader.active) {
                        let cloudPlayView = cloudPlayLoader.item;
                        let catalogBtn = cloudPlayView ? cloudPlayView.catalogButtonItem : null;
                        console.log("[Remote Play Tab] Cloud Play view exists:", !!cloudPlayView, "catalogButtonItem exists:", !!catalogBtn);
                        if (catalogBtn) {
                            console.log("[Remote Play Tab] Focusing catalogButton");
                            Qt.callLater(() => {
                                catalogBtn.forceActiveFocus(Qt.TabFocusReason);
                                console.log("[Remote Play Tab] After focus, catalogButton.activeFocus:", catalogBtn.activeFocus);
                            });
                            return;
                        }
                    }
                    console.log("[Remote Play Tab] Navigating to Remote Play content");
                    if (hostsView.count > 0) {
                        hostsView.currentIndex = 0;
                        hostsView.forceActiveFocus();
                        console.log("[Remote Play Tab] Focused hostsView");
                    } else {
                        if (addManuallyButton.visible) {
                            addManuallyButton.forceActiveFocus();
                            console.log("[Remote Play Tab] Focused addManuallyButton");
                        } else if (enableLocalDiscoveryButton.visible) {
                            enableLocalDiscoveryButton.forceActiveFocus();
                            console.log("[Remote Play Tab] Focused enableLocalDiscoveryButton");
                        } else {
                            setupGuideButton.forceActiveFocus();
                            console.log("[Remote Play Tab] Focused setupGuideButton");
                        }
                    }
                }
                
                Keys.onReturnPressed: {
                    mainTabBar.currentIndex = 0;
                    event.accepted = true;
                }
                
                background: Rectangle {
                    color: parent.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.15) : "transparent"
                    border.color: parent.activeFocus ? "#00d4ff" : "transparent"
                    border.width: parent.activeFocus ? 1 : 0
                    radius: 4
                    
                    // Underline when selected
                    Rectangle {
                        anchors {
                            left: parent.left
                            right: parent.right
                            bottom: parent.bottom
                        }
                        height: 3
                        color: parent.parent.checked ? "#00d4ff" : "transparent"
                        radius: 1.5
                        
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                    
                    Behavior on color { ColorAnimation { duration: 200 } }
                    Behavior on border.color { ColorAnimation { duration: 200 } }
                }
                
                contentItem: Text {
                    text: parent.text
                    font: parent.font
                    color: parent.checked ? "#00d4ff" : (parent.activeFocus ? "#00d4ff" : Qt.rgba(255, 255, 255, 0.7))
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            TabButton {
                text: qsTr("Cloud Play")
                width: implicitWidth + 24
                font.pixelSize: 15
                font.weight: Font.Medium
                focusPolicy: Qt.StrongFocus
                
                // Keyboard navigation
                KeyNavigation.left: mainTabBar.itemAt(0) // Remote Play tab
                KeyNavigation.right: psnLoginHeaderButton
                Keys.onDownPressed: (event) => {
                    console.log("[Cloud Play Tab] Down pressed, currentIndex:", mainTabBar.currentIndex, "cloudPlayLoader.active:", cloudPlayLoader.active);
                    event.accepted = true;
                    if (mainTabBar.currentIndex === 1 && cloudPlayLoader.active) {
                        let cloudPlayView = cloudPlayLoader.item;
                        let catalogBtn = cloudPlayView ? cloudPlayView.catalogButtonItem : null;
                        console.log("[Cloud Play Tab] Cloud Play view exists:", !!cloudPlayView, "catalogButtonItem exists:", !!catalogBtn);
                        if (catalogBtn) {
                            console.log("[Cloud Play Tab] Focusing catalogButton, visible:", catalogBtn.visible, "enabled:", catalogBtn.enabled, "focusPolicy:", catalogBtn.focusPolicy);
                            Qt.callLater(() => {
                                catalogBtn.forceActiveFocus(Qt.TabFocusReason);
                                console.log("[Cloud Play Tab] After focus, catalogButton.activeFocus:", catalogBtn.activeFocus, "parent visible:", catalogBtn.parent ? catalogBtn.parent.visible : "no parent");
                            });
                            return;
                        }
                    }
                    console.log("[Cloud Play Tab] Navigating to Remote Play content");
                    if (hostsView.count > 0) {
                        hostsView.currentIndex = 0;
                        hostsView.forceActiveFocus();
                        console.log("[Cloud Play Tab] Focused hostsView");
                    } else {
                        if (addManuallyButton.visible) {
                            addManuallyButton.forceActiveFocus();
                            console.log("[Cloud Play Tab] Focused addManuallyButton");
                        } else if (enableLocalDiscoveryButton.visible) {
                            enableLocalDiscoveryButton.forceActiveFocus();
                            console.log("[Cloud Play Tab] Focused enableLocalDiscoveryButton");
                        } else {
                            setupGuideButton.forceActiveFocus();
                            console.log("[Cloud Play Tab] Focused setupGuideButton");
                        }
                    }
                }
                
                Keys.onReturnPressed: (event) => {
                    mainTabBar.currentIndex = 1;
                    event.accepted = true;
                }
                
                background: Rectangle {
                    color: parent.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.15) : "transparent"
                    border.color: parent.activeFocus ? "#00d4ff" : "transparent"
                    border.width: parent.activeFocus ? 1 : 0
                    radius: 4
                    
                    // Underline when selected
                    Rectangle {
                        anchors {
                            left: parent.left
                            right: parent.right
                            bottom: parent.bottom
                        }
                        height: 3
                        color: parent.parent.checked ? "#00d4ff" : "transparent"
                        radius: 1.5
                        
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                    
                    Behavior on color { ColorAnimation { duration: 200 } }
                    Behavior on border.color { ColorAnimation { duration: 200 } }
                }
                
                contentItem: Text {
                    text: parent.text
                    font: parent.font
                    color: parent.checked ? "#00d4ff" : (parent.activeFocus ? "#00d4ff" : Qt.rgba(255, 255, 255, 0.7))
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }

        // Action buttons with futuristic styling (right side)
        RowLayout {
            anchors {
                right: parent.right
                top: parent.top
                bottom: parent.bottom
                rightMargin: 25
                topMargin: 15
                bottomMargin: 15
            }
            spacing: 15

            Button {
                id: psnLoginHeaderButton
                    Layout.preferredHeight: 48
                    Layout.preferredWidth: 48
                    flat: true
                    icon.source: {
                        // On cloud play tab, always show login icon
                        if (mainTabBar.currentIndex === 1) {
                            return "qrc:/icons/login-24px.svg";
                        }
                        // On remote play tab, show refresh if logged in, login if not
                        return Chiaki.settings.psnAuthToken ? "qrc:/icons/refresh-24px.svg" : "qrc:/icons/login-24px.svg";
                    }
                    icon.width: 24
                    icon.height: 24
                focusPolicy: Qt.StrongFocus
                hoverEnabled: true
                
                ToolTip.visible: hovered || activeFocus
                ToolTip.text: {
                    // On cloud play tab, always show "Update login tokens"
                    if (mainTabBar.currentIndex === 1) {
                        return qsTr("Update login tokens");
                    }
                    // On remote play tab, show current behavior
                    return Chiaki.settings.psnAuthToken ? qsTr("Refresh PSN Games") : qsTr("Login to PSN");
                }
                
                // Keyboard navigation
                KeyNavigation.left: mainTabBar.itemAt(1)  // Cloud Play tab
                KeyNavigation.right: settingsButton
                KeyNavigation.down: {
                    if (mainTabBar.currentIndex === 1 && cloudPlayLoader.active) {
                        let cloudPlayView = cloudPlayLoader.item;
                        return cloudPlayView ? cloudPlayView.catalogButtonItem : null;
                    }
                    // For remote play tab, navigate directly to hostsView or first button
                    return hostsView.count > 0 ? hostsView : (addManuallyButton.visible ? addManuallyButton : (enableLocalDiscoveryButton.visible ? enableLocalDiscoveryButton : setupGuideButton));
                }
                
                // A button (Key_Return) support
                Keys.onReturnPressed: {
                    clicked();
                    event.accepted = true;
                }
                    onClicked: {
                        // On cloud play tab, always open login dialog
                        if (mainTabBar.currentIndex === 1) {
                            root.showPSNTokenDialog("", false);
                        } else {
                            // On remote play tab, use current behavior
                            if (Chiaki.settings.psnAuthToken) {
                                // Show immediate feedback toast
                                errorTitleLabel.text = qsTr("Refreshing");
                                errorTextLabel.text = qsTr("Updating PSN games...");
                                errorToast.color = "#2196F3";
                                errorHideTimer.start();
                                
                                Chiaki.refreshPsnToken()
                            } else {
                                root.showPSNTokenDialog("", false)
                            }
                        }
                    }
                    // Always visible now
                    
                    background: Rectangle {
                        radius: 8
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
            }

            Button {
                id: settingsButton
                    Layout.preferredHeight: 48
                    Layout.preferredWidth: 48
                flat: true
                    icon.source: "qrc:/icons/settings-20px.svg"
                    icon.width: 24
                    icon.height: 24
                focusPolicy: Qt.StrongFocus
                hoverEnabled: true
                onClicked: root.showSettingsDialog()
                
                // Keyboard navigation
                KeyNavigation.left: psnLoginHeaderButton
                KeyNavigation.right: closeButton
                KeyNavigation.down: {
                    if (mainTabBar.currentIndex === 1 && cloudPlayLoader.active) {
                        let cloudPlayView = cloudPlayLoader.item;
                        return cloudPlayView ? cloudPlayView.catalogButtonItem : null;
                    }
                    // For remote play tab, navigate directly to hostsView or first button
                    return hostsView.count > 0 ? hostsView : (addManuallyButton.visible ? addManuallyButton : (enableLocalDiscoveryButton.visible ? enableLocalDiscoveryButton : setupGuideButton));
                }
                
                // A button (Key_Return) support
                Keys.onReturnPressed: {
                    clicked();
                    event.accepted = true;
                }
                    
                    background: Rectangle {
                        radius: 8
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
                    Layout.preferredHeight: 48
                    Layout.preferredWidth: 48
                    flat: true
                    text: "×"
                    font.pixelSize: 24
                    font.weight: Font.Bold
                    focusPolicy: Qt.StrongFocus
                    hoverEnabled: true
                    onClicked: Qt.quit()
                    
                    ToolTip.visible: hovered || activeFocus
                    ToolTip.text: qsTr("Exit")
                    
                    // Keyboard navigation
                    KeyNavigation.left: settingsButton
                    KeyNavigation.down: {
                        if (mainTabBar.currentIndex === 1 && cloudPlayLoader.active) {
                            let cloudPlayView = cloudPlayLoader.item;
                            return cloudPlayView ? cloudPlayView.catalogButtonItem : null;
                        }
                        // For remote play tab, navigate directly to hostsView or first button
                        return hostsView.count > 0 ? hostsView : (addManuallyButton.visible ? addManuallyButton : (enableLocalDiscoveryButton.visible ? enableLocalDiscoveryButton : setupGuideButton));
                    }
                    
                    // A button (Key_Return) support
                    Keys.onReturnPressed: (event) => {
                        clicked();
                        event.accepted = true;
                    }
                    
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
                        anchors.fill: parent
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                }
            }
    }

    // Tab View Content
    StackLayout {
        id: mainTabView
        anchors {
            top: headerBar.bottom
            left: parent.left
            right: parent.right
            bottom: buttonHintsFooter.top
        }
        currentIndex: mainTabBar.currentIndex
        
        // Remote Play Tab
        Item {
            // Console Cards Grid
            ScrollView {
                id: scrollView
                anchors {
                    fill: parent
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
                color: "#50d4ff"
                opacity: 0.7
            }
        }

        GridView {
            id: hostsView
            keyNavigationWraps: true
            cellWidth: width / 2
            cellHeight: 240
        model: Chiaki.hosts
            
            // Custom property to track selected card for highlighting
            property int selectedIndex: -1
            
            // When GridView gets focus, ensure we have a valid current item
            onActiveFocusChanged: {
                if (activeFocus && count > 0 && currentIndex < 0) {
                    currentIndex = 0;
                    selectedIndex = 0;
                }
            }
            
            // Handle key navigation for console cards
            Keys.onLeftPressed: {
                if (selectedIndex > 0) {
                    selectedIndex = selectedIndex - 1;
                    currentIndex = selectedIndex;
                }
            }
            
            Keys.onRightPressed: {
                if (selectedIndex < count - 1) {
                    selectedIndex = selectedIndex + 1;
                    currentIndex = selectedIndex;
                }
            }
            
            Keys.onUpPressed: {
                let itemsPerRow = Math.floor(width / cellWidth);
                let newIndex = Math.max(0, selectedIndex - itemsPerRow);
                if (newIndex === selectedIndex) {
                    // We're in top row, go to header (tab bar)
                    if (mainTabBar) {
                        mainTabBar.itemAt(0).forceActiveFocus();
                    }
                    selectedIndex = -1;
                } else {
                    selectedIndex = newIndex;
                    currentIndex = selectedIndex;
                }
            }
            
            Keys.onDownPressed: {
                let itemsPerRow = Math.floor(width / cellWidth);
                let newIndex = Math.min(count - 1, selectedIndex + itemsPerRow);
                if (newIndex === selectedIndex) {
                    // We're in bottom row, check if we're on the last console
                    let currentRow = Math.floor(selectedIndex / itemsPerRow);
                    let totalRows = Math.ceil(count / itemsPerRow);
                    let isLastRow = currentRow === totalRows - 1;
                    let isLastItem = selectedIndex === count - 1;
                    
                    if (isLastRow && isLastItem && floatingDiscoveryButton.visible) {
                        // On the last console, go to discovery button
                        floatingDiscoveryButton.forceActiveFocus();
                        selectedIndex = -1;
                    } else {
                        // Can't move down further, stay where we are
                        selectedIndex = newIndex;
                        currentIndex = selectedIndex;
                    }
                } else {
                    selectedIndex = newIndex;
                    currentIndex = selectedIndex;
                }
            }
            
            Keys.onReturnPressed: {
                if (currentItem && currentItem.connectToHost) {
                    currentItem.connectToHost();
                }
            }
            
            // Console action shortcuts - perform the action directly (no button click)
            Keys.onPressed: (event) => {
                if (event.modifiers)
                    return;
                switch (event.key) {
                // Support both Settings mapping keys (Backslash/C) and QmlController fallbacks (No/Yes)
                case Qt.Key_Backslash:
                case Qt.Key_No:
                    if (currentItem && currentItem.triggerFirstAction && currentItem.triggerFirstAction())
                        event.accepted = true;
                    break;
                case Qt.Key_C:
                case Qt.Key_Yes:
                    // Y/Triangle button - prioritize games menu if available
                    if (currentItem && currentItem.hasGames && currentItem.viewGames) {
                        currentItem.viewGames();
                        event.accepted = true;
                    } else if (currentItem && currentItem.triggerSecondAction && currentItem.triggerSecondAction()) {
                        event.accepted = true;
                    }
                    break;
                case Qt.Key_Backspace:
                    if (currentItem && currentItem.canHide) {
                        currentItem.deleteHost();
                        event.accepted = true;
                    }
                    break;
                }
            }
            
            Keys.onEscapePressed: {
                // Always pass ESC up to parent for quit dialog
                // Force the main pane to handle quit dialog
                root.showConfirmDialog(qsTr("Quit"), qsTr("Are you sure you want to quit?"), () => Qt.quit(), null, true);
            }

                                      // Remove GridView highlight - using per-card highlighting instead
            
        onCountChanged: {
            // Only update focus if MainView is actually active (not in settings or other dialogs)
            if (StackView.status !== StackView.Active)
                return;
            
            // Additional check: only update if we're the only item in the stack
            // This prevents interfering when dialogs/settings are open on top of MainView
            if (StackView.view && StackView.view.depth > 1)
                return;
                
            if(!hostsView.currentItem && hostsView.count > 0) {
                hostsView.currentIndex = 0;
                hostsView.selectedIndex = 0;
            }
            if(!hostsView.currentItem)
                return;
            if(!hostsView.currentItem.visible)
            {
                for(var i = 0; i < hostsView.count; i++)
                {
                    hostsView.currentIndex = (hostsView.currentIndex + 1) % hostsView.count;
                    if(hostsView.currentItem.visible)
                    {
                        break;
                    }
                }
            }
        }
            
            delegate: Item {
                id: delegateItem
                width: hostsView.cellWidth
                height: hostsView.cellHeight
                
                // Make the delegate focusable
                focus: hostsView.selectedIndex === index
                activeFocusOnTab: true
                
                // Expose modelData so footer can access it
                property var hostData: modelData
                
                // Booleans to express availability of actions without exposing buttons
                property bool canHide: modelData.manual || (modelData.discovered && !modelData.registered)
                property bool canWake: modelData.registered && !modelData.duid && !modelData.discovered
                property bool canPin: modelData.registered
                property bool hasGames: {
                    if (!modelData.duid) return false
                    let gamesJson = Chiaki.getPsnInstalledGames()
                    if (!gamesJson || gamesJson === "{}") return false
                    try {
                        let devices = JSON.parse(gamesJson)
                        let device = devices[modelData.duid]
                        return device && device.games && device.games.length > 0
                    } catch (e) {
                        return false
                    }
                }

                // Trigger first/second available actions directly
                function triggerFirstAction() {
                    if (canHide) { deleteHost(); return true; }
                    if (canWake) { wakeUpHost(); return true; }
                    if (canPin) { setConsolePin(); return true; }
                    return false;
                }
                function triggerSecondAction() {
                    var seen = 0;
                    if (canHide) { seen++; if (seen === 2) { deleteHost(); return true; } }
                    if (canWake) { seen++; if (seen === 2) { wakeUpHost(); return true; } }
                    if (canPin)  { seen++; if (seen === 2) { setConsolePin(); return true; } }
                    return false;
                }
                
                // Console Card
                Rectangle {
                    id: consoleCard
                    anchors {
                        fill: parent
                        margins: 15
                    }
                    radius: 12
                    color: {
                        if (hostsView.selectedIndex === index) return Qt.rgba(80/255, 212/255, 255/255, 0.15);
                        if (mouseArea.containsMouse) return Qt.rgba(80/255, 212/255, 255/255, 0.1);
                        return Qt.rgba(80/255, 212/255, 255/255, 0.05);
                    }
                    border.color: hostsView.selectedIndex === index ? "#50d4ff" : Qt.rgba(255, 255, 255, 0.1)
                    border.width: hostsView.selectedIndex === index ? 2 : 1
                    
                    Behavior on color { ColorAnimation { duration: 200 } }
                    Behavior on border.color { ColorAnimation { duration: 200 } }
                    
                    // removed outer glow to avoid blue rectangle outside card
                    

                    
                    MouseArea {
                        id: mouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            hostsView.currentIndex = index;
                            hostsView.selectedIndex = index;
                            hostsView.forceActiveFocus();  // Ensure GridView has focus
                            delegateItem.connectToHost();
                        }
                    }
                    
                    ColumnLayout {
                anchors {
                    fill: parent
                            margins: 22
                            bottomMargin: 15
                        }
                        spacing: 15
                        
                        // Console icon and status with gamepad shortcuts in top right
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 15
                            
                            Rectangle {
                                Layout.preferredWidth: 100
                                Layout.preferredHeight: 100
                                radius: 8
                                color: Qt.rgba(0, 212/255, 255/255, 0.1)
                                border.color: Qt.rgba(0, 212/255, 255/255, 0.3)
                                border.width: 1

                Image {
                                    anchors.centerIn: parent
                                    width: 80
                                    height: 80
                    fillMode: Image.PreserveAspectFit
                    source: "image://svg/console-ps" + (modelData.ps5 ? "5" : "4") + (modelData.state == "standby" ? "#light_standby" : "#light_on")
                                    sourceSize: Qt.size(80, 80)
                                }
                            }
                            
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                
                                Label {
                                    Layout.fillWidth: true
                                    text: modelData.name || qsTr("Unknown Console")
                                    font.pixelSize: 24
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
                                    font.pixelSize: 16
                                    color: "#00d4ff"
                                    elide: Text.ElideRight
                                }
                                
                                Label {
                                    Layout.fillWidth: true
                                    text: qsTr("State: %1").arg(modelData.state)
                                    font.pixelSize: 15
                                    color: Qt.rgba(255, 255, 255, 0.7)
                                    elide: Text.ElideRight
                            }
                        }
                        
                                                        // Gamepad shortcuts indicators (top right corner)
                            Item {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 32
                                Layout.alignment: Qt.AlignTop
                                visible: canHide || canWake || canPin
                                
                                // First action indicator (Square/X)
                                Item {
                                    id: firstActionIndicator
                                    anchors.right: parent.right
                                    anchors.rightMargin: 12
                                    anchors.top: parent.top
                                    width: firstActionText.width + firstActionImage.width + 6
                                    height: 20
                                    visible: canHide || canWake || canPin
                                    
                                    Text {
                                        id: firstActionText
                                        anchors.right: firstActionImage.left
                                        anchors.rightMargin: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: canHide ? (modelData.manual ? "Delete" : "Hide") : (canWake ? "Wake" : "Pin")
                                        font.pixelSize: 14
                                        font.weight: Font.Medium
                                        color: Qt.rgba(255, 255, 255, 0.8)
                                    }
                                    
                                    Image {
                                        id: firstActionImage
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 20
                                        height: 20
                                        sourceSize: Qt.size(40, 40)
                                        source: root.controllerButton("box")
                                        opacity: 0.85
                                        smooth: true
                                        antialiasing: true
                                    }
                                    
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: {
                                            if (canHide) {
                                                delegateItem.deleteHost();
                                            } else if (canWake) {
                                                delegateItem.wakeUpHost();
                                            } else if (canPin) {
                                                delegateItem.setConsolePin();
                                            }
                                        }
                                        cursorShape: Qt.PointingHandCursor
                                        z: 200
                                        hoverEnabled: true
                                    }
                                }
                                
                                // Second action indicator (Triangle/Y) - if multiple actions available
                                Item {
                                    id: secondActionIndicator
                                    anchors.right: parent.right
                                    anchors.rightMargin: 12
                                    anchors.top: firstActionIndicator.bottom
                                    anchors.topMargin: 4
                                    width: secondActionText.width + secondActionImage.width + 6
                                    height: 20
                                    visible: (canHide?1:0) + (canWake?1:0) + (canPin?1:0) >= 2
                                    
                                    Text {
                                        id: secondActionText
                                        anchors.right: secondActionImage.left
                                        anchors.rightMargin: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: (canHide && canWake) ? "Wake" : (canHide && !canWake && canPin) ? "Pin" : (!canHide && canWake && canPin) ? "Pin" : ""
                                        font.pixelSize: 14
                                        font.weight: Font.Medium
                                        color: Qt.rgba(255, 255, 255, 0.8)
                                    }
                                    
                                    Image {
                                        id: secondActionImage
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 20
                                        height: 20
                                        sourceSize: Qt.size(40, 40)
                                        source: root.controllerButton("pyramid")
                                        opacity: 0.85
                                        smooth: true
                                        antialiasing: true
                                    }
                                    
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: {
                                            var actionCount = 0;
                                            if (canHide) actionCount++;
                                            if (canWake) actionCount++;
                                            if (canPin) actionCount++;

                                            if (actionCount >= 2) {
                                                if (canHide && canWake) {
                                                    delegateItem.wakeUpHost();
                                                } else if (canHide && canPin) {
                                                    delegateItem.setConsolePin();
                                                } else if (canWake && canPin) {
                                                    delegateItem.setConsolePin();
                                                }
                                            }
                                        }
                                        cursorShape: Qt.PointingHandCursor
                                        z: 200
                                        hoverEnabled: true
                                    }
                                }
                                
                                // Games button (Triangle/Y) - shown if console has games
                                Item {
                                    id: gamesButton
                                    anchors.right: parent.right
                                    anchors.rightMargin: 12
                                    anchors.top: secondActionIndicator.visible ? secondActionIndicator.bottom : firstActionIndicator.bottom
                                    anchors.topMargin: 4
                                    width: gamesText.width + gamesImage.width + 6
                                    height: 20
                                    visible: hasGames  // Only show if console actually has games
                                    
                                    Text {
                                        id: gamesText
                                        anchors.right: gamesImage.left
                                        anchors.rightMargin: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "Installed"
                                        font.pixelSize: 14
                                        font.weight: Font.Medium
                                        color: Qt.rgba(255, 255, 255, 0.8)
                                    }
                                    
                                    Image {
                                        id: gamesImage
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 20
                                        height: 20
                                        sourceSize: Qt.size(40, 40)
                                        source: root.controllerButton("pyramid")
                                        opacity: 0.85
                                        smooth: true
                                        antialiasing: true
                                    }
                                    
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: {
                                            delegateItem.viewGames()
                                        }
                                        cursorShape: Qt.PointingHandCursor
                                        z: 200
                                        hoverEnabled: true
                                    }
                                }
                            }
                        }
                        
                        // Console details (IP only, smaller)
                        Rectangle {
                                Layout.fillWidth: true
                            Layout.preferredHeight: 38
                            radius: 6
                            color: Qt.rgba(0, 0, 0, 0.2)
                            
                            Label {
                                anchors {
                                    fill: parent
                                    margins: 8
                                }
                                    text: modelData.address ? qsTr("IP: %1").arg(Chiaki.settings.streamerMode ? "hidden" : modelData.address) : ""
                                    font.pixelSize: 14
                                    color: Qt.rgba(255, 255, 255, 0.7)
                                    elide: Text.ElideRight
                                    verticalAlignment: Text.AlignVCenter
                                }
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
            
            function viewGames() {
                if (modelData.duid) {
                    root.showGamesView(modelData.duid, modelData.name, index);
                }
            }
        } 
        }
            }
        }
        
        // Cloud Play Tab
        Loader {
            id: cloudPlayLoader
            source: "CloudPlayView.qml"
            active: mainTabBar.currentIndex === 1
            onItemChanged: {
                if (item) {
                    item.mainTabBar = mainTabBar
                    item.settingsButton = settingsButton
                }
            }
            onLoaded: {
                if (item) {
                    item.mainTabBar = mainTabBar
                    item.settingsButton = settingsButton
                    // Ensure games are loaded when the loader becomes active
                    if (mainTabBar.currentIndex === 1) {
                        Qt.callLater(() => {
                            if (item.currentSection === "catalog") {
                                item.loadPsnowCatalog();
                            } else {
                                item.loadPs5CloudLibrary();
                            }
                        });
                    }
                }
            }
        }
    }

    // Old footer removed - merged into buttonHintsFooter below

    // No consoles state
    Rectangle {
        id: noConsolesDialog
        anchors.centerIn: parent
        width: Math.max(480, contentColumn.implicitWidth + 60)
        height: contentColumn.implicitHeight + 60
        radius: 12
        color: Qt.rgba(10/255, 15/255, 26/255, 0.9)
        border.color: Qt.rgba(0, 212/255, 255/255, 0.3)
        border.width: 1
        visible: hostsView.count === 0 && mainTabBar.currentIndex === 0  // Only show on Remote Play tab
        
        // Focus management for keyboard/gamepad navigation
        onVisibleChanged: {
            if (visible) {
                // Set focus to the most relevant button when dialog appears
                Qt.callLater(() => {
                    if (addManuallyButton.visible) {
                        addManuallyButton.forceActiveFocus()
                    } else if (enableLocalDiscoveryButton.visible) {
                        enableLocalDiscoveryButton.forceActiveFocus()
                    }
                })
            }
        }
        
        // Update dialog when hosts are added/removed
        Connections {
            target: Chiaki
            function onHostsChanged() {
                console.log("MainView: Hosts changed, count is now:", hostsView.count);
                
                // Don't automatically steal focus when hosts are discovered
                // Users can navigate to the hosts manually if needed
            }
        }

                ColumnLayout {
            id: contentColumn
            anchors.centerIn: parent
            width: 450
            spacing: 20
            
            Label {
                Layout.alignment: Qt.AlignHCenter
                text: qsTr("No Consoles Found")
                font.pixelSize: 24
                font.weight: Font.Bold
                color: "#00d4ff"
            }
            
            // Main description text
            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                Layout.maximumWidth: 420
                text: qsTr("Make sure Remote Play is enabled on your console and you're connected to the same WiFi network.")
                font.pixelSize: 13
                color: Qt.rgba(255, 255, 255, 0.7)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
            
            // Remote Play Setup Instructions
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 420
                Layout.preferredHeight: instructionsColumn.implicitHeight + 30
                radius: 8
                color: Qt.rgba(0, 212/255, 255/255, 0.05)
                border.color: Qt.rgba(0, 212/255, 255/255, 0.2)
                border.width: 1
                
                Column {
                    id: instructionsColumn
                    anchors.centerIn: parent
                    width: parent.width - 30
                    spacing: 16
                    
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: qsTr("Enable Remote Play on your console:")
                        font.pixelSize: 14
                        font.weight: Font.Medium
                        color: "#00d4ff"
                    }
                    
                    Column {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 8
                        
                        Label {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: qsTr("PS5: Settings → System → Remote Play")
                            font.pixelSize: 12
                            color: Qt.rgba(255, 255, 255, 0.85)
                            font.family: "monospace"
                            horizontalAlignment: Text.AlignHCenter
                        }
                        
                        Label {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: qsTr("PS4: Settings → Remote Play Connection Settings")
                            font.pixelSize: 12
                            color: Qt.rgba(255, 255, 255, 0.85)
                            font.family: "monospace"
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }
                }
            }
            
            // Button column for console addition options
            ColumnLayout {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 10
                spacing: 12
                
                // Add Manually Button (Primary option)
                    Button {
                    id: addManuallyButton
                    Layout.preferredWidth: 300
                    Layout.preferredHeight: 50
                    text: qsTr("Add Console Manually")
                    font.pixelSize: 14
                    font.weight: Font.Medium
                    onClicked: root.showManualHostDialog()
                    
                    // Keyboard navigation
                    KeyNavigation.up: mainTabBar.itemAt(0)
                    KeyNavigation.down: enableLocalDiscoveryButton.visible ? enableLocalDiscoveryButton : setupGuideButton
                    
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
                
                // Description for Add Manually
                Label {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.fillWidth: true
                    Layout.maximumWidth: 300
                    Layout.topMargin: -12
                    text: qsTr("Only needed if automatic discovery doesn't work")
                    font.pixelSize: 12
                    color: Qt.rgba(255, 255, 255, 0.6)
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }
                
                // Enable Local Discovery Button (Secondary option)
                Button {
                    id: enableLocalDiscoveryButton
                    Layout.preferredWidth: 300
                    Layout.preferredHeight: 50
                    text: qsTr("Enable Local Discovery")
                    font.pixelSize: 14
                    font.weight: Font.Medium
                    visible: !Chiaki.discoveryEnabled
                    onClicked: Chiaki.discoveryEnabled = true
                    
                    // Keyboard navigation
                    KeyNavigation.up: addManuallyButton
                    KeyNavigation.down: setupGuideButton
                    
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
                
                // Description for Local Discovery
    Label {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.fillWidth: true
                    Layout.maximumWidth: 300
                    Layout.topMargin: -12
                    text: qsTr("Automatically finds consoles on your local network")
                    font.pixelSize: 12
                    color: Qt.rgba(255, 255, 255, 0.6)
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    visible: !Chiaki.discoveryEnabled
                }
                
                // Setup Guide Button (Tertiary option)
                Button {
                    id: setupGuideButton
                    Layout.preferredWidth: 300
                    Layout.preferredHeight: 50
                    text: qsTr("Setup Guide")
                    font.pixelSize: 14
                    font.weight: Font.Medium
                    onClicked: {
                        console.log("Setup Guide button clicked - calling showConsoleSetupWalkthrough");
                        root.showConsoleSetupWalkthrough();
                    }
                    
                    // Keyboard navigation
                    KeyNavigation.up: enableLocalDiscoveryButton.visible ? enableLocalDiscoveryButton : addManuallyButton
                    KeyNavigation.down: hostsView.count > 0 ? hostsView : (floatingDiscoveryButton.visible ? floatingDiscoveryButton : null)
                    
                    background: Rectangle {
                        radius: 6
                        color: parent.activeFocus ? Qt.rgba(255, 255, 255, 0.1) : Qt.rgba(255, 255, 255, 0.05)
                        border.color: parent.activeFocus ? Qt.rgba(255, 255, 255, 0.5) : Qt.rgba(255, 255, 255, 0.2)
                        border.width: 1
                        
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: Qt.rgba(255, 255, 255, 0.1)
                            opacity: parent.parent.hovered ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                    }
                    
                    contentItem: Text {
                        text: parent.text
                        font: parent.font
                        color: parent.activeFocus ? "#ffffff" : Qt.rgba(255, 255, 255, 0.7)
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                }
                
                // Description for Setup Guide
                Label {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.fillWidth: true
                    Layout.maximumWidth: 300
                    Layout.topMargin: -8
                    text: qsTr("Complete walkthrough for setting up consoles")
                    font.pixelSize: 11
                    color: Qt.rgba(255, 255, 255, 0.5)
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }
            }
        }
    }
    
    // Button hints overlay footer
    Rectangle {
        id: buttonHintsFooter
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        height: 40
        color: Qt.rgba(0, 0, 0, 0.6)
        z: 100  // Ensure it's above other content
        
        Item {
            anchors.fill: parent
            
            // Left side buttons - Different hints for Remote Play vs Cloud Play
            RowLayout {
                anchors.left: parent.left
                anchors.leftMargin: 15
                anchors.verticalCenter: parent.verticalCenter
                spacing: 15
                
                // Remote Play hints (shown when mainTabBar.currentIndex === 0)
                // Connect hint
                RowLayout {
                    spacing: 6
                    visible: mainTabBar.currentIndex === 0
                    Image {
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        sourceSize: Qt.size(36, 36)
                        source: root.controllerButton("cross")
                        opacity: 0.9
                        smooth: true
                        antialiasing: true
                    }
                    Label {
                        text: qsTr("Connect")
                        font.pixelSize: 13
                        font.weight: Font.Medium
                        color: "white"
                    }
                }
                
                // Games hint (Y button - shown only if console has games)
                RowLayout {
                    spacing: 6
                    visible: mainTabBar.currentIndex === 0 && hostsView.currentItem !== null && hostsView.currentItem.hasGames
                    Image {
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        sourceSize: Qt.size(36, 36)
                        source: root.controllerButton("pyramid")
                        opacity: 0.9
                        smooth: true
                        antialiasing: true
                    }
                    Label {
                        text: qsTr("Installed")
                        font.pixelSize: 13
                        font.weight: Font.Medium
                        color: "white"
                    }
                }
                
                // Dynamic action hint (X button - Delete/Hide/Wake/Pin based on selected console)
                RowLayout {
                    spacing: 6
                    visible: mainTabBar.currentIndex === 0 && hostsView.currentItem && hostsView.currentItem.hostData && (hostsView.currentItem.canHide || hostsView.currentItem.canWake || hostsView.currentItem.canPin)
                    Image {
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        sourceSize: Qt.size(36, 36)
                        source: root.controllerButton("box")
                        opacity: 0.9
                        smooth: true
                        antialiasing: true
                    }
                    Label {
                        text: {
                            if (!hostsView.currentItem) return ""
                            var item = hostsView.currentItem
                            if (!item.hostData) return ""
                            // Match the exact logic from the console card (line 948)
                            if (item.canHide) {
                                return item.hostData.manual ? qsTr("Delete") : qsTr("Hide")
                            }
                            if (item.canWake) {
                                return qsTr("Wake")
                            }
                            if (item.canPin) {
                                return qsTr("Pin")
                            }
                            return ""
                        }
                        font.pixelSize: 13
                        font.weight: Font.Medium
                        color: "white"
                    }
                }
                
                // Cloud Play hints (shown when mainTabBar.currentIndex === 1)
                // Stream Game hint (A/Cross button)
                RowLayout {
                    spacing: 6
                    visible: mainTabBar.currentIndex === 1
                    Image {
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        sourceSize: Qt.size(36, 36)
                        source: root.controllerButton("cross")
                        opacity: 0.9
                        smooth: true
                        antialiasing: true
                    }
                    Label {
                        text: qsTr("Stream")
                        font.pixelSize: 13
                        font.weight: Font.Medium
                        color: "white"
                    }
                }
                
                // Shortcut hint (X/Square button)
                RowLayout {
                    spacing: 6
                    visible: mainTabBar.currentIndex === 1
                    Image {
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        sourceSize: Qt.size(36, 36)
                        source: root.controllerButton("box")
                        opacity: 0.9
                        smooth: true
                        antialiasing: true
                    }
                    Label {
                        text: qsTr("Shortcut")
                        font.pixelSize: 13
                        font.weight: Font.Medium
                        color: "white"
                    }
                }
            }
            
            // Center - Version number (absolutely centered)
            Label {
                anchors.centerIn: parent
                text: Qt.application.version
                font.pixelSize: 12
                color: Qt.rgba(255, 255, 255, 0.5)
                horizontalAlignment: Text.AlignHCenter
            }
            
            // Right side - Exit hint (right-aligned)
            RowLayout {
                anchors.right: parent.right
                anchors.rightMargin: 15
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                Image {
                    Layout.preferredWidth: 18
                    Layout.preferredHeight: 18
                    sourceSize: Qt.size(36, 36)
                    source: root.controllerButton("moon")
                    opacity: 0.9
                    smooth: true
                    antialiasing: true
                }
                Label {
                    text: qsTr("Exit")
                    font.pixelSize: 13
                    font.weight: Font.Medium
                    color: "white"
                }
            }
        }
    }
    
    // Floating "Console Discovery" button - bottom left corner (Remote Play only)
    Button {
        id: floatingDiscoveryButton
        anchors {
            left: parent.left
            bottom: buttonHintsFooter.top
            leftMargin: 25
            bottomMargin: 25
        }
        width: 56
        height: 56
        visible: mainTabBar.currentIndex === 0  // Only visible on Remote Play tab
        focusPolicy: Qt.StrongFocus
        checkable: true
        checked: Chiaki.discoveryEnabled
        onToggled: Chiaki.discoveryEnabled = !Chiaki.discoveryEnabled
        hoverEnabled: true
        
        ToolTip.visible: hovered || activeFocus
        ToolTip.text: qsTr("Console Discovery")
        
        // Keyboard navigation
        KeyNavigation.right: floatingAddButton
        KeyNavigation.up: hostsView.count === 0 ? (setupGuideButton.visible ? setupGuideButton : (addManuallyButton.visible ? addManuallyButton : enableLocalDiscoveryButton)) : (hostsView.count > 0 ? hostsView : null)
        
        Keys.onReturnPressed: {
            toggle();
            event.accepted = true;
        }
        
        background: Rectangle {
            radius: width / 2  // Perfect circle
            color: {
                if (parent.activeFocus) return Qt.rgba(255, 255, 255, 0.15)
                else if (parent.checked) return Qt.rgba(0, 212/255, 255/255, 0.2)
                else return Qt.rgba(255, 255, 255, 0.1)
            }
            border.color: parent.activeFocus ? "#00d4ff" : (parent.checked ? "#00d4ff" : Qt.rgba(255, 255, 255, 0.3))
            border.width: parent.activeFocus ? 2 : 1
            
            // Shadow effect
            Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                radius: parent.radius + 2
                color: Qt.rgba(0, 0, 0, 0.25)
                z: -1
            }
            
            // Hover effect
            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                color: "#00d4ff"
                opacity: parent.parent.hovered ? 0.15 : 0
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
        }
        
        icon.source: "qrc:/icons/discover-" + (checked ? "" : "off-") + "24px.svg"
        icon.width: 24
        icon.height: 24
        icon.color: checked ? "#00d4ff" : Qt.rgba(255, 255, 255, 0.8)
    }
    
    // Floating "Add Console Manually" button - bottom right corner (Remote Play only)
    Button {
        id: floatingAddButton
        anchors {
            right: parent.right
            bottom: buttonHintsFooter.top
            rightMargin: 25
            bottomMargin: 25
        }
        width: 56
        height: 56
        visible: mainTabBar.currentIndex === 0  // Only visible on Remote Play tab
        focusPolicy: Qt.StrongFocus
        hoverEnabled: true
        onClicked: root.showManualHostDialog()
        
        ToolTip.visible: hovered || activeFocus
        ToolTip.text: qsTr("Add Console Manually")
        
        // Keyboard navigation
        KeyNavigation.left: floatingDiscoveryButton
        KeyNavigation.up: hostsView.count > 0 ? hostsView : (addManuallyButton.visible ? addManuallyButton : enableLocalDiscoveryButton.visible ? enableLocalDiscoveryButton : setupGuideButton)
        
        Keys.onReturnPressed: {
            clicked();
            event.accepted = true;
        }
        
        background: Rectangle {
            radius: width / 2  // Perfect circle
            color: parent.activeFocus ? Qt.rgba(255, 255, 255, 0.15) : Qt.rgba(255, 255, 255, 0.1)
            border.color: parent.activeFocus ? "#00d4ff" : Qt.rgba(255, 255, 255, 0.3)
            border.width: parent.activeFocus ? 2 : 1
            
            // Shadow effect
            Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                radius: parent.radius + 2
                color: Qt.rgba(0, 0, 0, 0.25)
                z: -1
            }
            
            // Hover effect
            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                color: "#00d4ff"
                opacity: parent.parent.hovered ? 0.15 : 0
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
        }
        
        icon.source: "qrc:/icons/add-24px.svg"
        icon.width: 24
        icon.height: 24
        icon.color: Qt.rgba(255, 255, 255, 0.9)
    }
}