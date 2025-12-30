import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Effects

import org.streetpea.chiaking

Pane {
    id: root
    padding: 0
    
    property var mainTabBar: null
    property var settingsButton: null
    
    // Expose child components for navigation
    readonly property Item catalogButtonItem: catalogButton
    readonly property Item searchContainerItem: searchContainer
    readonly property Item refreshButtonItem: refreshButton
    
    property int currentPage: 0
    property int gamesPerPage: 25
    property var allGames: []
    property var filteredGames: []
    property var currentPageGames: []
    property string currentSection: "catalog" // "catalog" or "library"
    property bool isLoading: false
    property string searchQuery: ""
    property string authErrorMessage: "" // Persistent auth error message
    
    // Clean blue background
    CleanBlueBackground {
        anchors.fill: parent
        z: -2
    }
    
    function controllerButton(name) {
        let type = "deck";
        for (let i = 0; i < Chiaki.controllers.length; ++i) {
            if (Chiaki.controllers[i].playStation) {
                type = "ps";
                break;
            }
        }
        return `image://svg/button-${type}#${name}`;
    }
    
    Component.onCompleted: {
        // Load saved cloud section on startup
        let savedSection = Chiaki.settings.lastSelectedCloudSection;
        if (savedSection === "library" || savedSection === "catalog") {
            currentSection = savedSection;
        }
        // Load games when component is first created
        Qt.callLater(() => {
            if (currentSection === "catalog") {
                loadPsnowCatalog();
            } else {
                loadPs5CloudLibrary();
            }
        });
    }
    
    // Watch for visibility changes to reload if needed
    onVisibleChanged: {
        if (visible && allGames.length === 0) {
            // Only load if we don't have games yet
            if (currentSection === "catalog") {
                loadPsnowCatalog();
            } else {
                loadPs5CloudLibrary();
            }
        }
    }
    
    StackView.onActivated: {
        // Also load when StackView activates this view
        Qt.callLater(() => {
            if (currentSection === "catalog") {
                loadPsnowCatalog();
            } else {
                loadPs5CloudLibrary();
            }
        });
    }
    
    // Handle RB/LB navigation for section switching
    Keys.onPressed: (event) => {
        if (event.modifiers)
            return;
        
        switch (event.key) {
        case Qt.Key_PageUp:
            // L1 button - switch to Cloud Catalog
            if (currentSection !== "catalog") {
                switchSection("catalog");
                event.accepted = true;
            }
            break;
        case Qt.Key_PageDown:
            // R1 button - switch to Game Library
            if (currentSection !== "library") {
                switchSection("library");
                event.accepted = true;
            }
            break;
        }
    }
    
    function loadPsnowCatalog() {
        // Check NPSSO token - show warning if missing (but still load games)
        let npssoToken = Chiaki.settings.psnNpssoToken;
        if (!npssoToken || npssoToken.trim().length === 0) {
            authErrorMessage = "NPSSO token is required for cloud play. Please login to PSN and enter a valid NPSSO token. You also need a valid PS Plus subscription.";
        } else {
            authErrorMessage = ""; // Clear auth error if token exists
        }
        
        // Clear old cards immediately when starting to load
        allGames = [];
        filteredGames = [];
        currentPageGames = [];
        isLoading = true;
        Chiaki.cloudCatalog.fetchPsnowCatalog(function(success, message, jsonData) {
            isLoading = false;
            if (success && jsonData) {
                try {
                    let data = JSON.parse(jsonData);
                    if (data.games && Array.isArray(data.games)) {
                        allGames = data.games;
                        // Don't clear auth error on success - keep it if token is still missing
                        if (npssoToken && npssoToken.trim().length > 0) {
                            authErrorMessage = "";
                        }
                        applySearchFilter();
                        // Set focus after games are loaded
                        Qt.callLater(() => {
                            if (gamesGrid.count > 0) {
                                gamesGrid.currentIndex = 0;
                                gamesGrid.forceActiveFocus();
                            }
                        });
                    } else {
                        allGames = [];
                        filteredGames = [];
                        currentPageGames = [];
                        showErrorToast(qsTr("Error"), qsTr("No games found in catalog"));
                    }
                } catch (e) {
                    console.error("Failed to parse PSNOW catalog:", e);
                    allGames = [];
                    filteredGames = [];
                    currentPageGames = [];
                    showErrorToast(qsTr("Parse Error"), qsTr("Failed to parse catalog data: %1").arg(e.toString()));
                }
            } else {
                console.error("Failed to fetch PSNOW catalog:", message);
                allGames = [];
                filteredGames = [];
                currentPageGames = [];
                showErrorToast(qsTr("API Error"), message || qsTr("Failed to fetch PSNOW catalog"));
            }
        });
    }
    
    function loadPs5CloudLibrary() {
        // Clear old cards immediately when starting to load
        allGames = [];
        filteredGames = [];
        currentPageGames = [];
        isLoading = true;
        Chiaki.cloudCatalog.getOwnedPs5CloudGames(function(success, message, jsonData) {
            isLoading = false;
            if (success && jsonData) {
                try {
                    let data = JSON.parse(jsonData);
                    if (data.games && Array.isArray(data.games)) {
                        allGames = data.games;
                        authErrorMessage = ""; // Clear auth error on success
                        applySearchFilter();
                        // Set focus after games are loaded
                        Qt.callLater(() => {
                            if (gamesGrid.count > 0) {
                                gamesGrid.currentIndex = 0;
                                gamesGrid.forceActiveFocus();
                            }
                        });
                    } else {
                        allGames = [];
                        filteredGames = [];
                        currentPageGames = [];
                        authErrorMessage = ""; // Clear auth error on success
                        showErrorToast(qsTr("Error"), qsTr("No cloud streamable games found in library"));
                    }
                } catch (e) {
                    console.error("Failed to parse PS5 cloud library:", e);
                    allGames = [];
                    filteredGames = [];
                    currentPageGames = [];
                    showErrorToast(qsTr("Parse Error"), qsTr("Failed to parse library data: %1").arg(e.toString()));
                }
            } else {
                console.error("Failed to fetch PS5 cloud library:", message);
                allGames = [];
                filteredGames = [];
                currentPageGames = [];
                // Check if it's an authentication error
                let errorMsg = message || qsTr("Failed to fetch PS5 cloud library");
                if (errorMsg.includes("NPSSO") || errorMsg.includes("login") || errorMsg.includes("Authentication") || errorMsg.includes("PS Plus")) {
                    authErrorMessage = errorMsg;
                } else {
                    authErrorMessage = "";
                    showErrorToast(qsTr("API Error"), errorMsg);
                }
            }
        });
    }
    
    function applySearchFilter() {
        if (!searchQuery || searchQuery.trim() === "") {
            filteredGames = allGames.slice();
        } else {
            let query = searchQuery.toLowerCase().trim();
            filteredGames = allGames.filter(function(game) {
                let name = "";
                if (game.name) name = game.name.toLowerCase();
                else if (game.game_meta && game.game_meta.name) name = game.game_meta.name.toLowerCase();
                return name.includes(query);
            });
        }
        
        // For PSNOW catalog, show all games on one page (no pagination)
        if (currentSection === "catalog") {
            currentPageGames = filteredGames.slice();
        } else {
            currentPage = 0;
            updateCurrentPage();
        }
    }
    
    function updateCurrentPage() {
        let startIdx = currentPage * gamesPerPage;
        let endIdx = Math.min(startIdx + gamesPerPage, filteredGames.length);
        currentPageGames = filteredGames.slice(startIdx, endIdx);
    }
    
    function nextPage() {
        if ((currentPage + 1) * gamesPerPage < filteredGames.length) {
            currentPage++;
            updateCurrentPage();
        }
    }
    
    function previousPage() {
        if (currentPage > 0) {
            currentPage--;
            updateCurrentPage();
        }
    }
    
    function switchSection(section) {
        // Clear old cards immediately when switching sections
        allGames = [];
        filteredGames = [];
        currentPageGames = [];
        currentSection = section;
        currentPage = 0;
        searchQuery = "";
        // Save the selected section
        Chiaki.settings.lastSelectedCloudSection = section;
        // Don't clear auth error here - let the load functions handle it
        // Clear search field text using Qt.callLater to ensure it works
        Qt.callLater(() => {
            if (searchField) {
                searchField.text = "";
            }
        });
        if (section === "catalog") {
            loadPsnowCatalog();
        } else {
            authErrorMessage = ""; // Clear auth error when switching to library (it will be set if needed)
            loadPs5CloudLibrary();
        }
    }
    
    function showShortcutToast(title, message) {
        shortcutToastTitle.text = title;
        shortcutToastMessage.text = message;
        shortcutToast.color = "#2196F3";
        shortcutToastTimer.restart();
    }
    
    function showErrorToast(title, message) {
        errorToastTitle.text = title;
        errorToastMessage.text = message;
        errorToast.color = "#F44336";
        errorToastTimer.restart();
    }
    
    // Watch for search query changes
    onSearchQueryChanged: {
        applySearchFilter();
    }
    
    // Single unified header - production quality design
    Rectangle {
        id: toolBar
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
        }
        height: 75
        
        color: Qt.rgba(10/255, 20/255, 38/255, 0.95)
        
        // Subtle bottom border
        Rectangle {
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            height: 1
            color: Qt.rgba(0, 212/255, 255/255, 0.2)
        }
        
        RowLayout {
            anchors {
                fill: parent
                leftMargin: 25
                rightMargin: 25
                topMargin: 8
                bottomMargin: 8
            }
            spacing: 16
            
            // Search bar - icon that expands when focused (far left)
            Rectangle {
                id: searchContainer
                Layout.preferredHeight: 44
                Layout.preferredWidth: searchContainer.activeFocus || searchField.activeFocus || searchField.text.length > 0 ? 400 : 44
                radius: 22
                color: searchContainer.activeFocus || searchField.activeFocus ? Qt.rgba(255, 255, 255, 0.15) : Qt.rgba(255, 255, 255, 0.1)
                border.color: searchContainer.activeFocus || searchField.activeFocus ? "#00d4ff" : Qt.rgba(255, 255, 255, 0.2)
                border.width: searchContainer.activeFocus || searchField.activeFocus ? 2 : 1
                focusPolicy: Qt.StrongFocus
                
                Behavior on Layout.preferredWidth {
                    NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
                }
                Behavior on color {
                    ColorAnimation { duration: 200 }
                }
                Behavior on border.color {
                    ColorAnimation { duration: 200 }
                }
                
                onActiveFocusChanged: {
                    if (activeFocus) {
                        Qt.callLater(() => {
                            searchField.forceActiveFocus();
                        });
                    }
                }
                
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Space || event.key === Qt.Key_Enter) {
                        searchField.forceActiveFocus();
                        event.accepted = true;
                    }
                }
                
                Keys.onLeftPressed: {
                    // Wrap to refresh button if at start
                    refreshButton.forceActiveFocus();
                    event.accepted = true;
                }
                
                Keys.onRightPressed: {
                    // Move to catalog button
                    catalogButton.forceActiveFocus();
                    event.accepted = true;
                }
                
                KeyNavigation.up: mainTabBar ? mainTabBar.itemAt(1) : null
                
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        searchField.forceActiveFocus();
                    }
                }
                
                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: searchField.activeFocus || searchField.text.length > 0 ? 16 : 0
                        rightMargin: searchField.activeFocus || searchField.text.length > 0 ? 16 : 0
                    }
                    spacing: 12
                    
                    // Search icon - visible when collapsed (custom magnifying glass icon)
                    Item {
                        Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
                        Layout.preferredWidth: 20
                        Layout.preferredHeight: 20
                        visible: !searchContainer.activeFocus && !searchField.activeFocus && searchField.text.length === 0
                        
                        Canvas {
                            anchors.fill: parent
                            onPaint: {
                                var ctx = getContext("2d");
                                ctx.strokeStyle = searchField.activeFocus ? "#00d4ff" : Qt.rgba(255, 255, 255, 0.7);
                                ctx.lineWidth = 2;
                                ctx.lineCap = "round";
                                
                                // Draw magnifying glass circle
                                ctx.beginPath();
                                ctx.arc(8, 8, 5, 0, 2 * Math.PI);
                                ctx.stroke();
                                
                                // Draw handle
                                ctx.beginPath();
                                ctx.moveTo(12, 12);
                                ctx.lineTo(16, 16);
                                ctx.stroke();
                            }
                        }
                    }
                    
                    TextField {
                        id: searchField
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        visible: searchField.activeFocus || searchField.text.length > 0
                        opacity: visible ? 1 : 0
                        placeholderText: qsTr("Search games...")
                        font.pixelSize: 14
                        color: "white"
                        selectByMouse: true
                        focusPolicy: Qt.StrongFocus
                        verticalAlignment: TextInput.AlignVCenter
                        topPadding: 0
                        bottomPadding: 0
                        background: Rectangle {
                            color: "transparent"
                        }
                        
                        Behavior on opacity {
                            NumberAnimation { duration: 200 }
                        }
                        
                        KeyNavigation.right: catalogButton
                        KeyNavigation.left: refreshButton
                        KeyNavigation.down: gamesGrid.count > 0 ? gamesGrid : null
                        
                        KeyNavigation.up: mainTabBar ? mainTabBar.itemAt(1) : null
                        
                        Keys.onLeftPressed: (event) => {
                            refreshButton.forceActiveFocus();
                            event.accepted = true;
                        }
                        
                        Keys.onReturnPressed: {
                            // When Enter is pressed, move focus to first game
                            if (gamesGrid.count > 0) {
                                gamesGrid.currentIndex = 0;
                                gamesGrid.forceActiveFocus();
                                event.accepted = true;
                            }
                        }
                        
                        onTextChanged: {
                            searchQuery = text;
                            // Maintain focus after text change
                            Qt.callLater(() => {
                                if (searchField) {
                                    searchField.forceActiveFocus();
                                }
                            });
                        }
                        
                        Keys.onEscapePressed: {
                            text = "";
                            searchQuery = "";
                            focus = false;
                        }
                        
                        onActiveFocusChanged: {
                            if (activeFocus) {
                                Qt.callLater(() => {
                                    if (searchField) {
                                        searchField.forceActiveFocus();
                                    }
                                });
                            }
                        }
                    }
                    
                    Button {
                        visible: searchField.text.length > 0
                        opacity: visible ? 1 : 0
                        text: "×"
                        font.pixelSize: 18
                        font.weight: Font.Bold
                        Layout.preferredWidth: 26
                        Layout.preferredHeight: 26
                        flat: true
                        focusPolicy: Qt.NoFocus
                        onClicked: {
                            searchField.text = "";
                            searchQuery = "";
                            searchField.forceActiveFocus();
                        }
                        
                        Behavior on opacity {
                            NumberAnimation { duration: 200 }
                        }
                        
                        background: Rectangle {
                            radius: 13
                            color: parent.hovered ? Qt.rgba(255, 255, 255, 0.2) : "transparent"
                        }
                    }
                }
            }
            
            // Section switcher - immediately to the right of search
            RowLayout {
                spacing: 10
                
                // Cloud Catalog button
                Button {
                    id: catalogButton
                    Layout.preferredHeight: 44
                    Layout.preferredWidth: 150
                    focusPolicy: Qt.StrongFocus
                    checked: currentSection === "catalog"
                    onClicked: switchSection("catalog")
                    
                    KeyNavigation.left: searchContainer
                    KeyNavigation.right: libraryButton
                    KeyNavigation.down: gamesGrid.count > 0 ? gamesGrid : null
                    
                    Keys.onLeftPressed: (event) => {
                        searchContainer.forceActiveFocus();
                        event.accepted = true;
                    }
                    
                    KeyNavigation.up: mainTabBar ? mainTabBar.itemAt(1) : null
                    
                    Keys.onReturnPressed: {
                        if (currentSection !== "catalog") {
                            switchSection("catalog");
                        }
                        event.accepted = true;
                    }
                    
                    background: Rectangle {
                        radius: 22
                        // Checked (active section) - solid bright blue background
                        // Focused (keyboard navigation) - subtle blue background with animated glow
                        // Neither - subtle gray
                        color: parent.checked ? Qt.rgba(0, 212/255, 255/255, 0.35) : (parent.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.18) : Qt.rgba(255, 255, 255, 0.08))
                        border.color: parent.checked ? "#00d4ff" : (parent.activeFocus ? "#00d4ff" : Qt.rgba(255, 255, 255, 0.15))
                        // When focused, use thicker border (3px) even if also checked
                        // When checked but not focused, use 2px
                        // When neither, use 1px
                        border.width: parent.activeFocus ? 3 : (parent.checked ? 2 : 1)
                        
                        // Focus glow effect (only when focused but not checked) - make it very visible
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "transparent"
                            border.color: "#00d4ff"
                            border.width: 2
                            opacity: parent.parent.activeFocus && !parent.parent.checked ? 0.7 : 0
                            visible: opacity > 0
                            
                            layer.enabled: parent.parent.activeFocus && !parent.parent.checked
                            layer.effect: MultiEffect {
                                blurEnabled: true
                                blurMax: 10
                                blur: 0.7
                            }
                            
                            Behavior on opacity { NumberAnimation { duration: 150 } }
                        }
                        
                        // Additional outer glow when focused (even if checked) - thicker border effect
                        Rectangle {
                            anchors {
                                fill: parent
                                margins: -1
                            }
                            radius: parent.radius + 1
                            color: "transparent"
                            border.color: "#00d4ff"
                            border.width: 1
                            opacity: parent.parent.activeFocus ? 0.5 : 0
                            visible: opacity > 0
                            
                            layer.enabled: parent.parent.activeFocus
                            layer.effect: MultiEffect {
                                blurEnabled: true
                                blurMax: 6
                                blur: 0.4
                            }
                            
                            Behavior on opacity { NumberAnimation { duration: 150 } }
                        }
                        
                        // Additional inner glow for checked state
                        Rectangle {
                            anchors {
                                fill: parent
                                margins: 2
                            }
                            radius: parent.radius - 2
                            color: parent.parent.checked ? Qt.rgba(0, 212/255, 255/255, 0.2) : "transparent"
                            visible: parent.parent.checked
                            
                            Behavior on color { ColorAnimation { duration: 150 } }
                        }
                        
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Behavior on border.color { ColorAnimation { duration: 150 } }
                        Behavior on border.width { NumberAnimation { duration: 150 } }
                    }
                    
                    contentItem: Text {
                        text: qsTr("Cloud Catalog")
                        font.pixelSize: 14
                        font.weight: parent.parent.checked ? Font.Medium : (parent.parent.activeFocus ? Font.Medium : Font.Normal)
                        // Checked = bright cyan, Focused = bright cyan (but different background), Neither = gray
                        color: parent.parent.checked ? "#00d4ff" : (parent.parent.activeFocus ? "#00d4ff" : Qt.rgba(255, 255, 255, 0.7))
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideNone
                        
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }
                }
                
                // PS5 Game Library button
                Button {
                    id: libraryButton
                    Layout.preferredHeight: 44
                    Layout.preferredWidth: 160
                    focusPolicy: Qt.StrongFocus
                    checked: currentSection === "library"
                    onClicked: switchSection("library")
                    
                    KeyNavigation.left: catalogButton
                    KeyNavigation.right: refreshButton
                    KeyNavigation.down: gamesGrid.count > 0 ? gamesGrid : null
                    
                    Keys.onReturnPressed: {
                        if (currentSection !== "library") {
                            switchSection("library");
                        }
                        event.accepted = true;
                    }
                    
                    KeyNavigation.up: mainTabBar ? mainTabBar.itemAt(1) : null
                    
                    background: Rectangle {
                        radius: 22
                        // Checked (active section) - brighter blue background
                        // Focused (keyboard navigation) - subtle blue glow
                        // Neither - subtle gray
                        color: parent.checked ? Qt.rgba(0, 212/255, 255/255, 0.3) : (parent.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.12) : Qt.rgba(255, 255, 255, 0.08))
                        border.color: parent.checked ? "#00d4ff" : (parent.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.6) : Qt.rgba(255, 255, 255, 0.15))
                        // When focused, use thicker border (3px) even if also checked
                        // When checked but not focused, use 2px
                        // When neither, use 1px
                        border.width: parent.activeFocus ? 3 : (parent.checked ? 2 : 1)
                        
                        // Focus glow effect (only when focused but not checked)
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "transparent"
                            border.color: "#00d4ff"
                            border.width: 2
                            opacity: parent.parent.activeFocus && !parent.parent.checked ? 0.4 : 0
                            visible: opacity > 0
                            
                            Behavior on opacity { NumberAnimation { duration: 150 } }
                        }
                        
                        // Additional outer glow when focused (even if checked) - thicker border effect
                        Rectangle {
                            anchors {
                                fill: parent
                                margins: -1
                            }
                            radius: parent.radius + 1
                            color: "transparent"
                            border.color: "#00d4ff"
                            border.width: 1
                            opacity: parent.parent.activeFocus ? 0.5 : 0
                            visible: opacity > 0
                            
                            layer.enabled: parent.parent.activeFocus
                            layer.effect: MultiEffect {
                                blurEnabled: true
                                blurMax: 6
                                blur: 0.4
                            }
                            
                            Behavior on opacity { NumberAnimation { duration: 150 } }
                        }
                        
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Behavior on border.color { ColorAnimation { duration: 150 } }
                        Behavior on border.width { NumberAnimation { duration: 150 } }
                    }
                    
                    contentItem: Text {
                        text: qsTr("PS5 Game Library")
                        font.pixelSize: 14
                        font.weight: parent.parent.checked ? Font.Medium : Font.Normal
                        // Checked = bright cyan, Focused = cyan, Neither = gray
                        color: parent.parent.checked ? "#00d4ff" : (parent.parent.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.9) : Qt.rgba(255, 255, 255, 0.7))
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideNone
                        
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }
                }
            }
            
            Item { Layout.fillWidth: true }
            
            // Right side controls
            RowLayout {
                spacing: 0
                
                // Refresh button
                Button {
                    id: refreshButton
                    text: qsTr("Refresh")
                    font.pixelSize: 14
                    font.weight: Font.Medium
                    Layout.preferredHeight: 44
                    Layout.preferredWidth: 110
                    Layout.rightMargin: 4
                    enabled: !isLoading
                    focusPolicy: Qt.StrongFocus
                    onClicked: {
                        // Invalidate cache and reload
                        Chiaki.cloudCatalog.invalidateCache();
                        if (currentSection === "catalog") {
                            loadPsnowCatalog();
                        } else {
                            loadPs5CloudLibrary();
                        }
                    }
                    
                    KeyNavigation.left: libraryButton
                    KeyNavigation.down: gamesGrid.count > 0 ? gamesGrid : null
                    
                    Keys.onReturnPressed: {
                        clicked();
                        event.accepted = true;
                    }
                    
                    KeyNavigation.up: settingsButton
                    
                    background: Rectangle {
                        radius: 22
                        color: parent.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.3) : Qt.rgba(255, 255, 255, 0.1)
                        border.width: parent.activeFocus ? 2 : 1
                        border.color: parent.activeFocus ? "#00d4ff" : Qt.rgba(255, 255, 255, 0.25)
                        
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Behavior on border.color { ColorAnimation { duration: 150 } }
                    }
                    
                    contentItem: Text {
                        text: parent.text
                        font: parent.font
                        color: parent.enabled ? (parent.activeFocus ? "#ffffff" : Qt.rgba(255, 255, 255, 0.9)) : Qt.rgba(255, 255, 255, 0.4)
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideNone
                    }
                }
                
                // Game count label
                Label {
                    text: {
                        if (searchQuery && searchQuery.trim() !== "") {
                            return filteredGames.length > 0 ? qsTr("%1 of %2").arg(filteredGames.length).arg(allGames.length) : qsTr("No games");
                        } else {
                            return filteredGames.length > 0 ? qsTr("%1 games").arg(filteredGames.length) : qsTr("No games");
                        }
                    }
                    font.pixelSize: 12
                    opacity: 0.75
                    color: "white"
                    Layout.preferredWidth: 80
                    Layout.leftMargin: -6
                    horizontalAlignment: Text.AlignRight
                }
            }
        }
    }
    
    ColumnLayout {
        anchors.top: toolBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.topMargin: 15
        spacing: 0
        
        // Persistent authentication error banner
        Rectangle {
            id: authErrorBanner
            Layout.fillWidth: true
            Layout.preferredHeight: authErrorMessage.length > 0 ? 80 : 0
            visible: authErrorMessage.length > 0
            color: Qt.rgba(244/255, 67/255, 54/255, 0.15) // Red background with transparency
            border.color: "#F44336"
            border.width: 2
            clip: true
            
            Behavior on Layout.preferredHeight {
                NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
            }
            Behavior on opacity {
                NumberAnimation { duration: 200 }
            }
            
            RowLayout {
                anchors {
                    fill: parent
                    leftMargin: 25
                    rightMargin: 25
                    topMargin: 12
                    bottomMargin: 12
                }
                spacing: 16
                
                Item {
                    Layout.fillWidth: true
                }
                
                // Warning icon
                Text {
                    text: "⚠"
                    font.pixelSize: 32
                    color: "#F44336"
                    Layout.alignment: Qt.AlignVCenter
                }
                
                // Error message
                Label {
                    text: authErrorMessage
                    wrapMode: Text.Wrap
                    color: "#FFFFFF"
                    font.pixelSize: 14
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    Layout.alignment: Qt.AlignVCenter
                }
                
                Item {
                    Layout.fillWidth: true
                }
            }
        }
        
        // Loading indicator
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: isLoading
            
            BusyIndicator {
                anchors.centerIn: parent
                running: isLoading
            }
        }
        
        // Games Grid
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            
            ScrollView {
                id: scrollView
                anchors.fill: parent
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                anchors.bottomMargin: 0
                clip: true
                
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                contentWidth: availableWidth
                focus: false  // Don't take focus, let GridView handle it
                
                GridView {
                    id: gamesGrid
                    
                    // Property to force binding recalculation when needed
                    property int _layoutVersion: 0
                    
                    width: {
                        // Include count to ensure recalculation when model changes
                        let modelCount = count;
                        let version = _layoutVersion;
                        let availableWidth = scrollView.availableWidth;
                        let cols = Math.floor(availableWidth / cellWidth);
                        if (cols === 0) cols = 1;
                        // Return width for exactly that many columns (centered), but never exceed availableWidth
                        return Math.min(cols * cellWidth, availableWidth);
                    }
                    height: implicitHeight
                    // Center the grid horizontally using x positioning
                    // Include count to ensure recalculation when model changes
                    x: {
                        let modelCount = count;
                        let version = _layoutVersion;
                        let availableWidth = scrollView.availableWidth;
                        let gridWidth = width;
                        return Math.max(0, (availableWidth - gridWidth) / 2);
                    }
                    
                    // Force recalculation when availableWidth changes (e.g., window maximize/resize)
                    Connections {
                        target: scrollView
                        function onAvailableWidthChanged() {
                            Qt.callLater(() => {
                                gamesGrid._layoutVersion++;
                            });
                        }
                    }
                    cellWidth: 240
                    cellHeight: 380
                    focus: true
                    clip: true
                    interactive: false
                    flickableDirection: Flickable.VerticalFlick
                    boundsBehavior: Flickable.StopAtBounds
                    
                    KeyNavigation.up: searchField
                    
                    model: currentPageGames
                    highlightFollowsCurrentItem: true
                    keyNavigationEnabled: true
                    keyNavigationWraps: false
                    
                    highlight: Rectangle {
                        color: "transparent"
                        border.color: Material.accent
                        border.width: 3
                        radius: 8
                        z: 10
                    }
                    
                    delegate: CloudGameCard {
                        required property int index
                        required property var modelData
                        width: gamesGrid.cellWidth - 20
                        height: gamesGrid.cellHeight - 20
                        gameData: modelData
                        focus: false  // GridView handles focus, not individual cards
                        activeFocusOnTab: false
                        isPsnow: currentSection === "catalog"
                        
                        onStreamGame: (productId, platform, serviceType) => {
                            console.log("Stream game:", productId, platform, serviceType);
                            
                            // Show StreamView immediately with loading spinner
                            // Find Main component by traversing parent chain
                            let mainComp = root;
                            while (mainComp && !mainComp.showStreamView) {
                                mainComp = mainComp.parent;
                            }
                            if (mainComp && mainComp.showStreamView) {
                                mainComp.showStreamView();
                            }
                            
                            // For PSCloud, use entitlement ID (gameData.id), for PSNOW use productId
                            let streamingIdentifier = productId;
                            if (serviceType === "pscloud" && gameData && gameData.id) {
                                streamingIdentifier = gameData.id; // Use entitlement ID for PSCloud
                            }
                            
                            Chiaki.cloudStreaming.startCompleteCloudSession(
                                serviceType,
                                streamingIdentifier,
                                function(success, message, serverIp) {
                                    console.log("Cloud streaming:", success ? "SUCCESS" : "FAILED");
                                    console.log("Result:", message);
                                    if (success) {
                                        console.log("Allocated Server IP:", serverIp);
                                    } else {
                                        // Error is handled by backend emitting sessionError signal
                                        // StreamView will automatically show error and return to main view
                                        // Check if it's an OAuth error for longer toast duration
                                        let isOAuthError = message && (message.includes("OAuth") || message.includes("authorization"));
                                        let toastDuration = isOAuthError ? 10000 : 3000; // 10 seconds for OAuth errors, 3 seconds otherwise
                                        Chiaki.error(qsTr("Cloud Streaming Failed"), message, toastDuration);
                                    }
                                }
                            );
                        }
                        
                        onCreateShortcut: (productId, platform, serviceType, gameName) => {
                            console.log("Create shortcut for cloud game:", gameName, productId, platform, serviceType);
                            
                            // Determine the command and identifier to use
                            let command;
                            let gameIdentifier = productId;
                            
                            if (serviceType === "psnow") {
                                command = "cloudGameCatalog";
                                // For PSNOW, use productId (will be converted to entitlementId by Kamaji)
                                gameIdentifier = productId;
                            } else if (serviceType === "pscloud") {
                                command = "cloudGameLibrary";
                                // For PSCloud, we need entitlement ID (the 'id' field from the entitlement object)
                                if (gameData && gameData.id) {
                                    gameIdentifier = gameData.id; // Use entitlement ID
                                } else {
                                    // Fallback to productId if id doesn't exist (shouldn't happen for library games)
                                    console.warn("PSCloud game missing entitlement ID, using productId as fallback");
                                    gameIdentifier = productId;
                                }
                            } else {
                                showErrorToast(qsTr("Error"), qsTr("Unknown service type: %1").arg(serviceType));
                                return;
                            }
                            
                            // Get image URL from gameData
                            let imageUrl = "";
                            if (gameData) {
                                if (gameData.extracted_images && gameData.extracted_images.cover) {
                                    imageUrl = gameData.extracted_images.cover;
                                } else if (gameData.extracted_images && gameData.extracted_images.landscape) {
                                    imageUrl = gameData.extracted_images.landscape;
                                } else if (gameData.imageUrl) {
                                    imageUrl = gameData.imageUrl;
                                }
                            }
                            
                            // Show the dialog (using showCloudDialog method)
                            cloudShortcutDialog.showCloudDialog(gameName, gameIdentifier, serviceType, command, imageUrl);
                        }
                    }
                    
                    Keys.onPressed: (event) => {
                        if (event.modifiers)
                            return;
                        
                        let cols = Math.floor(scrollView.availableWidth / cellWidth);
                        if (cols === 0) cols = 1;
                        
                        if (event.key === Qt.Key_Left) {
                            if (currentIndex % cols !== 0) {
                                currentIndex = Math.max(0, currentIndex - 1);
                            }
                            event.accepted = true;
                            return;
                        }
                        
                        if (event.key === Qt.Key_Right) {
                            let totalItems = model.length;
                            let colInRow = currentIndex % cols;
                            let isLastItem = currentIndex === totalItems - 1;
                            let isRightmostInRow = colInRow === cols - 1;
                            
                            if (!isLastItem && !isRightmostInRow) {
                                currentIndex = Math.min(totalItems - 1, currentIndex + 1);
                            }
                            event.accepted = true;
                            return;
                        }
                        
                        if (event.key === Qt.Key_Up) {
                            // Move up one row
                            let currentRow = Math.floor(currentIndex / cols);
                            if (currentRow > 0) {
                                let colInRow = currentIndex % cols;
                                let prevRowStartIndex = (currentRow - 1) * cols;
                                let targetIndex = prevRowStartIndex + colInRow;
                                currentIndex = Math.max(0, targetIndex);
                                positionViewAtIndex(currentIndex, GridView.Contain);
                                event.accepted = true;
                                return;
                            }
                            // If at top row, move focus to the unselected section switcher button
                            if (currentSection === "catalog") {
                                libraryButton.forceActiveFocus();
                            } else {
                                catalogButton.forceActiveFocus();
                            }
                            event.accepted = true;
                            return;
                        }
                        
                        if (event.key === Qt.Key_Down) {
                            let totalItems = model.length;
                            let currentRow = Math.floor(currentIndex / cols);
                            let nextRowStartIndex = (currentRow + 1) * cols;
                            let nextRowEndIndex = Math.min(nextRowStartIndex + cols - 1, totalItems - 1);
                            
                            if (nextRowStartIndex < totalItems) {
                                let colInRow = currentIndex % cols;
                                let targetIndex = nextRowStartIndex + colInRow;
                                
                                if (targetIndex <= nextRowEndIndex) {
                                    currentIndex = targetIndex;
                                } else {
                                    currentIndex = nextRowEndIndex;
                                }
                                positionViewAtIndex(currentIndex, GridView.Contain);
                            }
                            event.accepted = true;
                            return;
                        }
                        
                        // Square/X button - Create shortcut
                        if (event.key === Qt.Key_X || event.key === Qt.Key_Backslash || event.key === Qt.Key_No) {
                            if (currentItem && currentItem.createShortcut) {
                                let game = currentItem.modelData;
                                let productId = currentItem.getProductId();
                                let platform = currentItem.getPlatform();
                                let serviceType = currentItem.getServiceType();
                                let gameName = currentItem.getGameName();
                                if (productId !== "") {
                                    currentItem.createShortcut(productId, platform, serviceType, gameName);
                                    event.accepted = true;
                                }
                            }
                            return;
                        }
                        
                        switch (event.key) {
                        case Qt.Key_Escape:
                        case Qt.Key_Back:
                            event.accepted = true;
                            break;
                        case Qt.Key_PageDown:
                            let visibleRows = Math.floor(scrollView.availableHeight / cellHeight);
                            let jumpIndex = Math.min(currentIndex + (visibleRows * cols), model.length - 1);
                            currentIndex = jumpIndex;
                            positionViewAtIndex(currentIndex, GridView.Contain);
                            event.accepted = true;
                            break;
                        case Qt.Key_PageUp:
                            let visibleRowsUp = Math.floor(scrollView.availableHeight / cellHeight);
                            let jumpIndexUp = Math.max(currentIndex - (visibleRowsUp * cols), 0);
                            currentIndex = jumpIndexUp;
                            positionViewAtIndex(currentIndex, GridView.Contain);
                            event.accepted = true;
                            break;
                        }
                    }
                    
                    Component.onCompleted: {
                        if (model && model.length > 0) {
                            currentIndex = 0;
                        }
                    }
                    
                    onModelChanged: {
                        // Force layout recalculation after model changes
                        Qt.callLater(() => {
                            _layoutVersion++;
                        });
                        if (model && model.length > 0) {
                            if (currentIndex < 0) {
                                currentIndex = 0;
                            }
                            // Ensure focus when model changes
                            Qt.callLater(() => {
                                if (count > 0) {
                                    currentIndex = 0;
                                    forceActiveFocus();
                                }
                            });
                        }
                    }
                    
                    onCountChanged: {
                        // Force layout recalculation after count changes (including when going to 0)
                        Qt.callLater(() => {
                            _layoutVersion++;
                        });
                        if (count > 0) {
                            if (currentIndex < 0) {
                                currentIndex = 0;
                            }
                            // Set focus when items are added
                            Qt.callLater(() => {
                                if (count > 0) {
                                    currentIndex = 0;
                                    forceActiveFocus();
                                }
                            });
                        }
                    }
                    
                    // Ensure focus is maintained
                    onActiveFocusChanged: {
                        if (activeFocus && count > 0 && currentIndex < 0) {
                            currentIndex = 0;
                        }
                    }
                }
            }
        }
        
        // Pagination Footer (only for PS5 Library, not for PSNOW Catalog)
        RowLayout {
            id: paginationFooter
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? implicitHeight : 0
            Layout.bottomMargin: 20
            Layout.leftMargin: 40
            Layout.rightMargin: 40
            visible: currentSection === "library" && filteredGames.length > gamesPerPage && !isLoading
            
            Button {
                text: qsTr("← Previous")
                enabled: currentPage > 0
                onClicked: previousPage()
            }
            
            Item { Layout.fillWidth: true }
            
            Label {
                text: qsTr("Page %1 of %2").arg(currentPage + 1).arg(Math.ceil(filteredGames.length / gamesPerPage))
                font.pixelSize: 16
            }
            
            Item { Layout.fillWidth: true }
            
            Button {
                text: qsTr("Next →")
                enabled: (currentPage + 1) * gamesPerPage < filteredGames.length
                onClicked: nextPage()
            }
        }
    }
    
    // Cloud Shortcut Dialog (reusing GameShortcutDialog)
    GameShortcutDialog {
        id: cloudShortcutDialog
        anchors.centerIn: parent
        
        onShowToast: (message, color) => {
            shortcutToastTitle.text = qsTr("Notice")
            shortcutToastMessage.text = message
            shortcutToast.color = color
            shortcutToastTimer.restart()
        }
        
        onAllDialogsClosed: {
            // Restore focus to games grid after all dialogs close
            Qt.callLater(() => {
                if (gamesGrid.count > 0) {
                    gamesGrid.forceActiveFocus(Qt.TabFocusReason)
                }
            })
        }
        
        onClosed: {
            // Restore focus to games grid after dialog closes
            Qt.callLater(() => {
                if (gamesGrid.count > 0) {
                    gamesGrid.forceActiveFocus(Qt.TabFocusReason)
                }
            })
        }
    }
    
    // Toast notification for shortcut creation
    Rectangle {
        id: shortcutToast
        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
            bottomMargin: 80
        }
        color: Material.accent
        width: Math.max(shortcutToastTitle.implicitWidth, shortcutToastMessage.implicitWidth) + 40
        height: shortcutToastColumn.implicitHeight + 20
        radius: 8
        opacity: shortcutToastTimer.running ? 0.8 : 0.0
        z: 1000
        
        Behavior on opacity { NumberAnimation { duration: 300 } }
        Behavior on color { ColorAnimation { duration: 300 } }
        
        ColumnLayout {
            id: shortcutToastColumn
            anchors.centerIn: parent
            spacing: 5
            
            Label {
                id: shortcutToastTitle
                Layout.alignment: Qt.AlignCenter
                font.bold: true
                font.pixelSize: 16
                color: "white"
            }
            
            Label {
                id: shortcutToastMessage
                Layout.alignment: Qt.AlignCenter
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: 14
                color: "white"
            }
        }
        
        Timer {
            id: shortcutToastTimer
            interval: 3000
        }
    }
    
    // Error toast notification
    Rectangle {
        id: errorToast
        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
            bottomMargin: 80
        }
        color: "#F44336"
        width: Math.max(errorToastTitle.implicitWidth, errorToastMessage.implicitWidth) + 40
        height: errorToastColumn.implicitHeight + 20
        radius: 8
        opacity: errorToastTimer.running ? 0.9 : 0.0
        z: 1001
        
        Behavior on opacity { NumberAnimation { duration: 300 } }
        Behavior on color { ColorAnimation { duration: 300 } }
        
        ColumnLayout {
            id: errorToastColumn
            anchors.centerIn: parent
            spacing: 5
            
            Label {
                id: errorToastTitle
                Layout.alignment: Qt.AlignCenter
                font.bold: true
                font.pixelSize: 16
                color: "white"
            }
            
            Label {
                id: errorToastMessage
                Layout.alignment: Qt.AlignCenter
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: 14
                color: "white"
                wrapMode: Text.Wrap
                width: Math.min(implicitWidth, parent.parent.width - 40)
            }
        }
        
        Timer {
            id: errorToastTimer
            interval: 5000
        }
    }
    
}
