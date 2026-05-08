import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

Rectangle {
    id: card
    
    property var gameData
    property bool isHovered: false
    property bool isCurrentItem: GridView.isCurrentItem || false
    property bool hasFocus: isCurrentItem && GridView.view.activeFocus
    property bool isPsnow: true // true for PSNOW, false for PS5 Cloud
    property string cachedImageUrl: ""
    property string libraryFilter: "owned" // "owned" or "all" or "favorites" - filter mode for Game Library
    property var qrCodeDialog: null // Reference to QR code dialog
    property bool isFavorite: false // Whether this game is favorited
    
    // Steam library shortcut: only when Steamworks build + Steam client (same gate as createCloudSteamShortcut usefulness)
    readonly property bool showCloudSteamShortcut: Chiaki.cloudSteamShortcutEnabled
        && !(!isPsnow && libraryFilter === "all" && gameData && !gameData.isOwned)
    
    signal streamGame(string productId, string platform, string serviceType)
    signal createShortcut(string productId, string entitlementId, string platform, string serviceType, string gameName)
    signal toggleFavorite(string productId)
    
    // Generate controller button icon path
    function getControllerIcon(buttonName) {
        let type = "deck";
        for (let i = 0; i < Chiaki.controllers.length; ++i) {
            if (Chiaki.controllers[i].playStation) {
                type = "ps";
                break;
            }
        }
        return `image://svg/button-${type}#${buttonName}`;
    }
    
    // Extract game information
    function getGameName() {
        if (!gameData) return qsTr("Unknown Game");
        if (gameData.name) return gameData.name;
        if (gameData.game_meta && gameData.game_meta.name) return gameData.game_meta.name;
        return qsTr("Unknown Game");
    }
    
    // Get product ID (general purpose - may return entitlement ID for PSCloud if product_id not available)
    function getProductId() {
        if (!gameData) return "";
        // Prioritize product_id/productId over id
        if (gameData.product_id) return gameData.product_id; // Owned games (PSCloud library)
        if (gameData.productId) return gameData.productId; // Game catalog
        if (gameData.id) return gameData.id; // Fallback: PSNOW or if product_id/productId not available
        return "";
    }
    
    // Get product ID specifically for API calls (fetchGameDetails)
    // For PSCloud: returns product_id (not entitlement id)
    // For PSNOW: returns id (which is the product ID)
    function getProductIdForApi() {
        if (!gameData) return "";
        if (isPsnow) {
            // PSNOW: use id as productId
            return gameData.id || "";
        } else {
            // PSCloud: use product_id for API calls (not the entitlement id)
            if (gameData.product_id) {
                return gameData.product_id;
            } else if (gameData.productId) {
                return gameData.productId;
            }
            return "";
        }
    }
    
    // Get the identifier to use for streaming (entitlement ID for PSCloud, product ID for PSNOW)
    function getStreamingIdentifier() {
        if (!gameData) return "";
        if (isPsnow) {
            // PSNOW: use product ID (will be converted to entitlement ID by Kamaji)
            return getProductId();
        } else {
            // PSCloud: use entitlement ID (the 'id' field), fallback to product_id if id doesn't exist
            if (gameData.id) return gameData.id; // Entitlement ID for PSCloud library games
            if (gameData.product_id) return gameData.product_id; // Fallback
            if (gameData.productId) return gameData.productId; // Fallback for catalog games
            return "";
        }
    }
    
    function getPlatform() {
        if (!gameData) return "ps4";
        if (isPsnow) {
            // PSNOW games - check playable_platform
            // Note: When passed from C++ to QML, JSON arrays become QVariantList objects,
            // not true JavaScript arrays, so we need to handle both cases
            let playablePlatform = gameData.playable_platform || gameData["playable_platform"];
            
            if (playablePlatform) {
                // Convert to array if it's not already (handles QVariantList from C++)
                let platformArray = [];
                if (Array.isArray(playablePlatform)) {
                    platformArray = playablePlatform;
                } else if (typeof playablePlatform === "object" && playablePlatform.length !== undefined) {
                    for (let i = 0; i < playablePlatform.length; i++) {
                        platformArray.push(playablePlatform[i]);
                    }
                } else if (typeof playablePlatform === "string") {
                    platformArray = [playablePlatform];
                }
                
                // Check each platform in the array
                for (let i = 0; i < platformArray.length; i++) {
                    let platform = String(platformArray[i]);
                    if (platform.indexOf("PS3") !== -1) return "ps3";
                    if (platform.indexOf("PS4") !== -1) return "ps4";
                }
            }
            return "ps4";
        } else {
            return "ps5";
        }
    }
    
    function getServiceType() {
        return isPsnow ? "psnow" : "pscloud";
    }
    
    function getImageUrl() {
        if (!gameData) return "";
        
        // Check if we already have extracted images from previous fetch
        // Prefer cover over landscape
        if (gameData.extracted_images) {
            if (gameData.extracted_images.cover) return gameData.extracted_images.cover;
            if (gameData.extracted_images.landscape) return gameData.extracted_images.landscape;
        }
        
        // For PS5 Cloud games from gameslist API - they have imageUrl directly
        if (!isPsnow) {
            if (gameData.imageUrl) return gameData.imageUrl;
            if (gameData.images && Array.isArray(gameData.images) && gameData.images.length > 0) {
                // Prefer cover (type 10) over landscape (type 12/13)
                for (let i = 0; i < gameData.images.length; i++) {
                    let img = gameData.images[i];
                    if (img && img.url && img.type === 10) return img.url;
                }
                // Fallback to landscape if no cover
                for (let i = 0; i < gameData.images.length; i++) {
                    let img = gameData.images[i];
                    if (img && img.url && (img.type === 12 || img.type === 13)) return img.url;
                }
                // Last resort: any image
                for (let i = 0; i < gameData.images.length; i++) {
                    let img = gameData.images[i];
                    if (img && img.url) return img.url;
                }
            }
        } else {
            // For PSNOW games - catalog doesn't include images, need to fetch from details
            // But try any available fields first
            if (gameData.imageUrl) return gameData.imageUrl;
            if (gameData.images && Array.isArray(gameData.images)) {
                // Prefer cover (type 10) over landscape (type 12/13)
                for (let i = 0; i < gameData.images.length; i++) {
                    let img = gameData.images[i];
                    if (img && img.url && img.type === 10) return img.url;
                }
                // Fallback to landscape if no cover
                for (let i = 0; i < gameData.images.length; i++) {
                    let img = gameData.images[i];
                    if (img && img.url && (img.type === 12 || img.type === 13)) return img.url;
                }
            }
        }
        return "";
    }
    
    function getPlatformBadge() {
        let platform = getPlatform();
        if (platform === "ps5") return "PS5";
        if (platform === "ps4") return "PS4";
        if (platform === "ps3") return "PS3";
        return "";
    }
    
    // Note: cachedImageUrl is bound to gameImage.source below, so it will update automatically
    
    // Load image URL on component creation - ONLY from catalog/entitlement data, no API calls
    Component.onCompleted: {
        // Get initial image URL from catalog/entitlement data only
        let initialUrl = getImageUrl();
        if (initialUrl) {
            cachedImageUrl = initialUrl;
        }
        // For PSNOW games without images in catalog, show placeholder until shortcut is clicked
        // Game details will be fetched only when shortcut button is pressed
        // For PS5 Cloud games, images should come from the entitlements API response
    }
    
    color: isHovered || isCurrentItem ? Qt.lighter(Material.dialogColor, 1.1) : Material.dialogColor
    radius: 8
    border.width: 0
    border.color: "transparent"
    
    Behavior on color { ColorAnimation { duration: 150 } }
    
    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        onEntered: isHovered = true
        onExited: isHovered = false
        onClicked: parent.GridView.view.currentIndex = index
    }
    
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 6
        spacing: 4
        
        // Game Image with overlays
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 140
            color: "transparent"
            radius: 4
            clip: true
            
            Image {
                id: gameImage
                anchors.fill: parent
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: true
                smooth: true
                
                // Always bind to cachedImageUrl - will update when URL is set
                source: cachedImageUrl || ""
                
                // Suppress error warnings - image loading failures are non-fatal
                // QML Image component may not support all HTTPS image formats
                onStatusChanged: {
                    // Silently handle errors - don't retry as it just spams warnings
                    // Images will show placeholder if they fail to load
                }
                
                BusyIndicator {
                    anchors.centerIn: parent
                    running: gameImage.status === Image.Loading
                    visible: running
                }
                
                Label {
                    anchors.centerIn: parent
                    text: getGameName().substring(0, 2)
                    font.pixelSize: 48
                    font.bold: true
                    opacity: 0.3
                    visible: gameImage.status !== Image.Ready && !gameImage.status === Image.Loading
                }
            }
            
            // Favorite star button - Top Left (no background)
            Item {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.topMargin: 0
                anchors.leftMargin: 8
                width: 30
                height: 30
                
                Label {
                    id: favoriteStarLabel
                    anchors.centerIn: parent
                    text: card.isFavorite ? "★" : "☆"
                    font.pixelSize: 24
                    color: card.isFavorite ? "#FFD700" : "#FFFFFF"
                    style: Text.Outline
                    styleColor: "black"
                }
                
                MouseArea {
                    id: favoriteMouseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        let productId = getProductId();
                        if (productId) {
                            toggleFavorite(productId);
                        }
                        mouse.accepted = true;
                    }
                }
            }
            
            // Owned/Not Owned badge - Top Right
            Rectangle {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: 8
                anchors.rightMargin: 8
                width: ownedLabel.implicitWidth + 12
                height: 22
                radius: 4
                color: gameData && gameData.isOwned ? "#4CAF50" : "#FF9800"
                visible: !isPsnow && libraryFilter === "all"
                
                Label {
                    id: ownedLabel
                    anchors.centerIn: parent
                    text: gameData && gameData.isOwned ? qsTr("OWNED") : qsTr("NOT OWNED")
                    font.pixelSize: 10
                    font.weight: Font.Bold
                    color: "white"
                }
            }
            
            // Game Title overlay - Bottom (platform badge at end of row, matches Android item_cloud_game.xml)
            Rectangle {
                id: titleOverlay
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Math.max(titleRow.implicitHeight + 12, 36)
                color: Qt.rgba(0, 0, 0, 0.6)
                
                RowLayout {
                    id: titleRow
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    anchors.topMargin: 6
                    anchors.bottomMargin: 6
                    spacing: 6
                    
                    Label {
                        id: titleLabel
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        Layout.minimumWidth: 0
                        text: getGameName()
                        font.pixelSize: 14
                        font.bold: true
                        color: "white"
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        verticalAlignment: Text.AlignVCenter
                        wrapMode: Text.NoWrap
                    }
                    
                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        Layout.preferredWidth: platformLabel.implicitWidth + 12
                        Layout.preferredHeight: 24
                        radius: 4
                        color: Qt.rgba(0, 0, 0, 0.7)
                        visible: getPlatform() !== ""
                        
                        Label {
                            id: platformLabel
                            anchors.centerIn: parent
                            text: {
                                let platform = getPlatform();
                                if (platform === "ps3") return "3";
                                if (platform === "ps4") return "4";
                                if (platform === "ps5") return "5";
                                return "";
                            }
                            font.pixelSize: 14
                            font.weight: Font.Bold
                            color: "#FFD700"
                        }
                    }
                }
            }
        }
        
        // Action Buttons - fixed size to always fit
        ColumnLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: showCloudSteamShortcut ? 84 : 40  // 40 (stream) + optional 36 (shortcut) + 8 (spacing)
            spacing: 8
            visible: true
            
            // Stream Game — primary CTA without full neon slab (muted fill + accent ring; stronger on hover)
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                Layout.minimumHeight: 40
                Layout.maximumHeight: 40
                radius: 6
                readonly property color streamFillIdle: Qt.alpha(Material.accent, 0.2)
                readonly property color streamFillHover: Qt.alpha(Material.accent, 0.42)
                readonly property color streamBorderIdle: Qt.alpha(Material.accent, 0.55)
                readonly property color streamBorderHover: Qt.alpha(Material.accent, 0.95)
                color: streamMouseArea.containsMouse ? streamFillHover : streamFillIdle
                border.width: 1
                border.color: streamMouseArea.containsMouse ? streamBorderHover : streamBorderIdle
                
                Behavior on color { ColorAnimation { duration: 150 } }
                Behavior on border.color { ColorAnimation { duration: 150 } }
                
                MouseArea {
                    id: streamMouseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    
                    onClicked: {
                        console.log("[CloudGameCard] Button clicked - isPsnow:", isPsnow, "libraryFilter:", libraryFilter, "gameData:", gameData, "isOwned:", gameData ? gameData.isOwned : "N/A");
                        console.log("[CloudGameCard] qrCodeDialog:", qrCodeDialog);
                        
                        // Check if this is a non-owned game in "All" filter mode
                        if (!isPsnow && libraryFilter === "all" && gameData && !gameData.isOwned) {
                            console.log("[CloudGameCard] Condition met for QR code - showing dialog");
                            // Show QR code dialog with conceptUrl
                            let conceptUrl = gameData.conceptUrl || gameData.concept_url;
                            console.log("[CloudGameCard] conceptUrl:", conceptUrl);
                            console.log("[CloudGameCard] qrCodeDialog type:", typeof qrCodeDialog, "qrCodeDialog value:", qrCodeDialog);
                            
                            if (conceptUrl) {
                                console.log("[CloudGameCard] conceptUrl found:", conceptUrl);
                                if (qrCodeDialog) {
                                    console.log("[CloudGameCard] Calling qrCodeDialog.showDialog()");
                                    qrCodeDialog.showDialog(conceptUrl);
                                    console.log("[CloudGameCard] showDialog() called");
                                } else {
                                    console.error("[CloudGameCard] ERROR: qrCodeDialog is null/undefined!");
                                }
                            } else {
                                console.error("[CloudGameCard] ERROR: conceptUrl is missing!");
                            }
                        } else {
                            console.log("[CloudGameCard] Normal stream behavior");
                            // Normal stream behavior - use getStreamingIdentifier for correct ID
                            let streamingId = getStreamingIdentifier();
                            let platform = getPlatform();
                            let serviceType = getServiceType();
                            if (streamingId !== "") {
                                streamGame(streamingId, platform, serviceType);
                            }
                        }
                    }
                }
                
                Label {
                    anchors.centerIn: parent
                    text: {
                        if (!isPsnow && libraryFilter === "all" && gameData && !gameData.isOwned) {
                            return qsTr("Add Game")
                        }
                        return qsTr("Stream Game")
                    }
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    color: streamMouseArea.containsMouse ? "#FFFFFF" : "#DCECF3"
                    Behavior on color { ColorAnimation { duration: 150 } }
                }
            }
            
            // Shortcut button with Square/X icon (Steamworks + steam-shortcut build only; hidden for non-owned in "All" filter)
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 36
                Layout.minimumHeight: 36
                Layout.maximumHeight: 36
                visible: showCloudSteamShortcut
                radius: 6
                color: shortcutMouseArea.containsMouse ? Qt.rgba(255, 255, 255, 0.3) : Qt.rgba(255, 255, 255, 0.15)
                border.width: 1
                border.color: Qt.rgba(255, 255, 255, 0.2)
                
                Behavior on color { ColorAnimation { duration: 150 } }
                
                MouseArea {
                    id: shortcutMouseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    
                        onClicked: {
                            let productIdForApi = getProductIdForApi();
                            let entitlementId = getStreamingIdentifier(); // For PSCloud: entitlement ID, for PSNOW: product ID
                            let platform = getPlatform();
                            let serviceType = getServiceType();
                            let gameName = getGameName();
                            
                            if (productIdForApi !== "") {
                                // Open dialog - it will fetch game details itself using productIdForApi
                                // entitlementId is used for the launch command
                                console.log("[CloudGameCard] Opening shortcut dialog, productId for API:", productIdForApi, "entitlementId:", entitlementId, "isPsnow:", isPsnow);
                                createShortcut(productIdForApi, entitlementId, platform, serviceType, gameName);
                            } else {
                                console.warn("[CloudGameCard] Cannot create shortcut - missing product ID for API");
                            }
                        }
                }
                
                RowLayout {
                    anchors.centerIn: parent
                    spacing: 6
                    
                    Label {
                        text: qsTr("Shortcut")
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        color: "white"
                        verticalAlignment: Text.AlignVCenter
                    }
                    
                    Image {
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        sourceSize: Qt.size(36, 36)
                        source: getControllerIcon("box")
                        opacity: 0.9
                        smooth: true
                        antialiasing: true
                    }
                }
            }
        }
    }
    
    Keys.onPressed: (event) => {
        // Cross/A button (Enter/Space) - Stream game or show QR code
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Space || event.key === Qt.Key_Enter) {
            // Check if this is a non-owned game in "All" filter mode
            if (!isPsnow && libraryFilter === "all" && gameData && !gameData.isOwned) {
                // Show QR code dialog with conceptUrl
                let conceptUrl = gameData.conceptUrl || gameData.concept_url;
                if (conceptUrl && qrCodeDialog) {
                    qrCodeDialog.showDialog(conceptUrl);
                    event.accepted = true;
                }
            } else {
                // Normal stream behavior - use getStreamingIdentifier for correct ID
                let streamingId = getStreamingIdentifier();
                let platform = getPlatform();
                let serviceType = getServiceType();
                if (streamingId !== "") {
                    streamGame(streamingId, platform, serviceType);
                    event.accepted = true;
                }
            }
        }
        // Square/X button (X key) - Create shortcut
        else if (event.key === Qt.Key_X && showCloudSteamShortcut) {
            let productIdForApi = getProductIdForApi();
            let entitlementId = getStreamingIdentifier(); // For PSCloud: entitlement ID, for PSNOW: product ID
            let platform = getPlatform();
            let serviceType = getServiceType();
            let gameName = getGameName();
            
            if (productIdForApi !== "") {
                // Open dialog - it will fetch game details itself using productIdForApi
                // entitlementId is used for the launch command
                console.log("[CloudGameCard] Opening shortcut dialog (keyboard), productId for API:", productIdForApi, "entitlementId:", entitlementId, "isPsnow:", isPsnow);
                createShortcut(productIdForApi, entitlementId, platform, serviceType, gameName);
                event.accepted = true;
            } else {
                console.warn("[CloudGameCard] Cannot create shortcut (keyboard) - missing product ID for API");
            }
        }
    }
}

