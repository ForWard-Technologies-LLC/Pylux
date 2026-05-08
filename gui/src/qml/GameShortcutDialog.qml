import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

import "controls" as C

Dialog {
    id: dialog
    
    property string titleId: ""
    property string gameName: ""
    property string deviceName: ""
    property string currentState: "setup"  // "setup", "creating", "success", "failed"
    
    // Cloud streaming properties (mutually exclusive with remote play properties)
    property string gameIdentifier: ""
    property string serviceType: ""
    property string command: ""
    property string imageUrl: ""
    property string productId: ""  // Product ID used for cache lookup (may differ from gameIdentifier for PSCloud)
    property string cachedGameDetails: ""  // Fetched game details JSON
    property bool isCloudShortcut: false
    property bool isLoadingGameDetails: false  // True while waiting for game details to be fetched
    property bool fetchFailed: false  // True if API fetch failed (show error placeholder instead of fallback image)
    
    signal showToast(string message, string color)
    signal allDialogsClosed()
    
    title: currentState === "setup" ? qsTr("Create Steam Shortcut") :
           currentState === "creating" ? qsTr("Creating Steam Shortcut...") :
           currentState === "success" ? qsTr("✓ Shortcut Created Successfully") :
           qsTr("✗ Shortcut Creation Failed")
    
    modal: true
    width: 650
    height: currentState === "setup" ? 550 : 500
    closePolicy: Popup.NoAutoClose
    
    Material.roundedScale: Material.MediumScale
    
    function showDialog(gameTitle, gameTitleId, consoleDeviceName) {
        // Validate parameters
        if (!consoleDeviceName || !gameTitle) {
            dialog.showToast(qsTr("⚠ Error: Missing required information"), "#F44336")
            return
        }
        
        // Reset to remote play mode
        isCloudShortcut = false
        currentState = "setup"
        titleId = gameTitleId
        gameName = gameTitle
        deviceName = consoleDeviceName
        
        // Populate fields
        gameNameField.text = gameTitle
        let escaped_console = consoleDeviceName.replace(/"/g, '\\"')
        let escaped_titleId = gameTitleId.replace(/"/g, '\\"')
        launchOptionsField.text = `--nickname "${escaped_console}" --title-id "${escaped_titleId}" launchTitle`
        coverImage.source = ChiakiGames.getGameImage(gameTitleId)
        
        open()
    }
    
    function showCloudDialog(gameTitle, gameIdentifierValue, serviceTypeValue, commandValue, productIdValue) {
        // Validate parameters
        if (!gameTitle || !gameIdentifierValue || !commandValue) {
            dialog.showToast(qsTr("⚠ Error: Missing required information"), "#F44336")
            return
        }
        
        // Reset to cloud shortcut mode
        isCloudShortcut = true
        currentState = "setup"
        gameIdentifier = gameIdentifierValue
        gameName = gameTitle
        serviceType = serviceTypeValue
        command = commandValue
        productId = productIdValue || ""  // Product ID for API fetch
        imageUrl = ""
        cachedGameDetails = ""
        fetchFailed = false
        isLoadingGameDetails = true  // Start loading - will fetch game details
        
        // Populate fields
        gameNameField.text = gameTitle
        let escaped_identifier = gameIdentifier.replace(/"/g, '\\"')
        if (command === "cloudGameCatalog") {
            launchOptionsField.text = `--product-id "${escaped_identifier}" cloudGameCatalog`
        } else if (command === "cloudGameLibrary") {
            launchOptionsField.text = `--entitlement-id "${escaped_identifier}" cloudGameLibrary`
        }
        
        // Clear image while loading
        coverImage.source = ""
        
        open()
        
        // Fetch game details after dialog opens
        if (productId) {
            console.log("[GameShortcutDialog] Fetching game details for productId:", productId);
            Chiaki.cloudCatalog.fetchGameDetails(productId, function(success, message, jsonData) {
                if (success && jsonData) {
                    try {
                        let details = JSON.parse(jsonData);
                        cachedGameDetails = jsonData;
                        fetchFailed = false;
                        isLoadingGameDetails = false;
                        
                        // Extract image URL
                        if (details.extracted_images) {
                            imageUrl = details.extracted_images.cover || details.extracted_images.landscape || "";
                            if (imageUrl) {
                                coverImage.source = imageUrl;
                            }
                        }
                    } catch (e) {
                        console.error("[GameShortcutDialog] Failed to parse game details:", e);
                        fetchFailed = true;
                        isLoadingGameDetails = false;
                    }
                } else {
                    console.error("[GameShortcutDialog] Failed to fetch game details:", message);
                    fetchFailed = true;
                    isLoadingGameDetails = false;
                }
            });
        } else {
            console.warn("[GameShortcutDialog] No productId provided, cannot fetch game details");
            fetchFailed = true;
            isLoadingGameDetails = false;
        }
    }
    
    
    onOpened: {
        // Focus the appropriate element based on state
        if (currentState === "setup") {
            createButton.forceActiveFocus()
        } else if (currentState === "success" || currentState === "failed") {
            closeButton.forceActiveFocus()
        }
    }
    
    onClosed: {
        allDialogsClosed()
    }
    
    // Global shortcut for B button (Escape) to close dialog
    Shortcut {
        sequence: "Escape"
        enabled: dialog.visible
        onActivated: dialog.close()
    }
    
    Shortcut {
        sequence: "Back"
        enabled: dialog.visible
        onActivated: dialog.close()
    }
    
    // Custom footer with state-dependent buttons
    footer: DialogButtonBox {
        Button {
            id: cancelButton
            text: qsTr("Cancel")
            visible: currentState === "setup"
            focusPolicy: Qt.StrongFocus
            KeyNavigation.right: createButton
            KeyNavigation.up: launchOptionsField
            
            onClicked: dialog.close()
            
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Space || event.key === Qt.Key_Enter) {
                    clicked()
                    event.accepted = true
                }
            }
            
            background: Rectangle {
                implicitWidth: 100
                implicitHeight: 40
                color: cancelButton.down ? Qt.darker(Material.background, 1.2) : 
                       cancelButton.hovered ? Qt.lighter(Material.background, 1.1) : Material.background
                border.color: cancelButton.activeFocus ? Material.accent : Qt.rgba(255, 255, 255, 0.3)
                border.width: cancelButton.activeFocus ? 2 : 1
                radius: 4
            }
        }
        
        Button {
            id: createButton
            text: qsTr("Create Shortcut")
            visible: currentState === "setup"
            highlighted: true
            focusPolicy: Qt.StrongFocus
            KeyNavigation.left: cancelButton
            KeyNavigation.up: launchOptionsField
            
            onClicked: {
                if (isCloudShortcut) {
                    // Cloud shortcut creation
                    // Check if we have pre-fetched details from the API call
                    // Note: createCloudSteamShortcut will handle product ID lookup internally for PSCloud
                    if (!cachedGameDetails || cachedGameDetails.length === 0) {
                        dialog.close()
                        dialog.showToast(qsTr("⚠ Game details are still loading. Please wait and try again."), "#FF9800")
                        return
                    }
                    
                    // Switch to creating state
                    currentState = "creating"
                    logArea.text = qsTr("Starting shortcut creation...\n")
                    
                    // Get Steam base directory
                    let steamDir = ""
                    try {
                        steamDir = Chiaki.getSteamBaseDir()
                    } catch (e) {
                        console.warn("Could not get Steam base dir:", e)
                    }
                    
                    // Start creation
                    Chiaki.cloudCatalog.createCloudSteamShortcut(
                        gameIdentifier,
                        gameNameField.text.trim(),
                        command,
                        function(msg, ok, done) {
                            logArea.text += msg + "\n"
                            
                            if (done) {
                                // Switch to success or failed state
                                currentState = ok ? "success" : "failed"
                                // Focus the close button
                                Qt.callLater(() => closeButton.forceActiveFocus())
                            }
                        },
                        steamDir
                    )
                } else {
                    // Remote play shortcut creation
                    // Validate cached data
                    let cachedData = ChiakiGames.getCachedStoreResponse(titleId)
                    if (!cachedData || cachedData.length === 0) {
                        dialog.close()
                        dialog.showToast(qsTr("⚠ Game artwork is still loading. Please wait and try again."), "#FF9800")
                        return
                    }
                    
                    // Switch to creating state
                    currentState = "creating"
                    logArea.text = qsTr("Starting shortcut creation...\n")
                    
                    // Start creation
                    ChiakiGames.createGameSteamShortcut(
                        titleId,
                        gameNameField.text.trim(),
                        function(msg, ok, done) {
                            logArea.text += msg + "\n"
                            
                            if (done) {
                                // Switch to success or failed state
                                currentState = ok ? "success" : "failed"
                                // Focus the close button
                                Qt.callLater(() => closeButton.forceActiveFocus())
                            }
                        },
                        "",
                        deviceName
                    )
                }
            }
            
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Space || event.key === Qt.Key_Enter) {
                    clicked()
                    event.accepted = true
                }
            }
            
            background: Rectangle {
                implicitWidth: 100
                implicitHeight: 40
                color: createButton.down ? Qt.darker(Material.accent, 1.2) : 
                       createButton.hovered ? Qt.lighter(Material.accent, 1.1) : Material.accent
                border.color: createButton.activeFocus ? "white" : "transparent"
                border.width: createButton.activeFocus ? 3 : 0
                radius: 4
            }
            
            contentItem: Text {
                text: createButton.text
                font: createButton.font
                color: "white"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
        }
        
        Button {
            id: closeButton
            text: qsTr("Close")
            visible: currentState === "success" || currentState === "failed"
            highlighted: true
            focusPolicy: Qt.StrongFocus
            
            onClicked: dialog.close()
            
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Space || event.key === Qt.Key_Enter) {
                    clicked()
                    event.accepted = true
                }
            }
            
            background: Rectangle {
                implicitWidth: 100
                implicitHeight: 40
                color: closeButton.down ? Qt.darker(Material.accent, 1.2) : 
                       closeButton.hovered ? Qt.lighter(Material.accent, 1.1) : Material.accent
                border.color: closeButton.activeFocus ? "white" : "transparent"
                border.width: closeButton.activeFocus ? 3 : 0
                radius: 4
            }
            
            contentItem: Text {
                text: closeButton.text
                font: closeButton.font
                color: "white"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
        }
    }
    
    contentItem: Item {
        // Setup content (visible in "setup" state)
        Flickable {
            id: setupContent
            anchors.fill: parent
            visible: currentState === "setup"
            contentWidth: availableWidth
            contentHeight: setupColumn.height
            clip: true
            
            ScrollBar.vertical: ScrollBar {}
            
            ColumnLayout {
                id: setupColumn
                width: parent.width
                spacing: 20
                
                // Cover art preview
                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: 200
                    Layout.preferredHeight: 200
                    color: "#1a1a1a"
                    radius: 8
                    visible: coverImage.status === Image.Ready || (isCloudShortcut && isLoadingGameDetails) || (isCloudShortcut && fetchFailed)
                    
                    Image {
                        id: coverImage
                        anchors.fill: parent
                        anchors.margins: 4
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        cache: true
                        visible: status === Image.Ready && !(isCloudShortcut && isLoadingGameDetails) && !(isCloudShortcut && fetchFailed)
                    }
                    
                    // Loading spinner for cloud shortcuts while waiting for game details
                    BusyIndicator {
                        anchors.centerIn: parent
                        running: isCloudShortcut && isLoadingGameDetails
                        visible: isCloudShortcut && isLoadingGameDetails
                    }
                    
                    // Error placeholder when API fetch fails
                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 8
                        visible: isCloudShortcut && fetchFailed && !isLoadingGameDetails
                        
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "⚠"
                            font.pixelSize: 48
                            color: "#F44336"
                        }
                        
                        Label {
                            Layout.alignment: Qt.AlignHCenter
                            text: qsTr("Image unavailable")
                            font.pixelSize: 12
                            color: "#888888"
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }
                }
                
                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    rowSpacing: 20
                    columnSpacing: 15
                    
                    Label {
                        Layout.alignment: Qt.AlignRight | Qt.AlignTop
                        text: isCloudShortcut ? qsTr("Service") : qsTr("Console")
                        font.weight: Font.Medium
                    }
                    
                    Label {
                        Layout.fillWidth: true
                        text: isCloudShortcut ? 
                              (serviceType === "psnow" ? "PSNOW" : serviceType === "pscloud" ? "PS Cloud" : serviceType) :
                              (deviceName || qsTr("(Unknown)"))
                        wrapMode: Text.Wrap
                        font.pixelSize: 14
                    }
                    
                    Label {
                        Layout.alignment: Qt.AlignRight | Qt.AlignTop
                        text: qsTr("Steam Game Name")
                        font.weight: Font.Medium
                    }
                    
                    C.TextField {
                        id: gameNameField
                        Layout.fillWidth: true
                        Layout.preferredWidth: 400
                        focusPolicy: Qt.StrongFocus
                        KeyNavigation.down: launchOptionsField
                        KeyNavigation.tab: launchOptionsField
                        
                        Keys.onReturnPressed: createButton.clicked()
                        Keys.onEnterPressed: createButton.clicked()
                    }
                    
                    Label {
                        Layout.alignment: Qt.AlignRight | Qt.AlignTop
                        text: qsTr("Launch Options")
                        font.weight: Font.Medium
                    }
                    
                    C.TextField {
                        id: launchOptionsField
                        Layout.fillWidth: true
                        Layout.preferredWidth: 400
                        focusPolicy: Qt.StrongFocus
                        KeyNavigation.up: gameNameField
                        KeyNavigation.down: createButton
                        KeyNavigation.backtab: gameNameField
                        KeyNavigation.tab: createButton
                        
                        Keys.onReturnPressed: createButton.clicked()
                        Keys.onEnterPressed: createButton.clicked()
                    }
                }
                
                Label {
                    Layout.fillWidth: true
                    text: isCloudShortcut ? 
                          qsTr("This will create a Steam shortcut that launches directly into this cloud game.") :
                          qsTr("This will create a Steam shortcut that launches directly into this game.")
                    wrapMode: Text.Wrap
                    opacity: 0.7
                    font.pixelSize: 12
                }
            }
        }
        
        // Log content (visible in "creating", "success", "failed" states)
        Flickable {
            id: logContent
            anchors.fill: parent
            visible: currentState !== "setup"
            clip: true
            contentWidth: width
            contentHeight: logArea.implicitHeight
            flickableDirection: Flickable.VerticalFlick
            boundsBehavior: Flickable.StopAtBounds
            
            ScrollBar.vertical: ScrollBar {
                id: logScrollbar
                policy: ScrollBar.AlwaysOn
            }
            
            Label {
                id: logArea
                width: parent.width - 20
                wrapMode: Text.Wrap
                font.family: "monospace"
                font.pixelSize: 13
                lineHeight: 1.3
                
                onTextChanged: {
                    // Auto-scroll to bottom
                    Qt.callLater(() => {
                        logContent.contentY = Math.max(0, logContent.contentHeight - logContent.height)
                    })
                }
                
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Up && logScrollbar.position > 0.001) {
                        logContent.flick(0, 500)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Down && logScrollbar.position < 1.0 - logScrollbar.size - 0.001) {
                        logContent.flick(0, -500)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (currentState === "success" || currentState === "failed") {
                            dialog.close()
                            event.accepted = true
                        }
                    }
                }
            }
        }
    }
}
