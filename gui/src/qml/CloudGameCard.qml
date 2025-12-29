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
    
    signal streamGame(string productId, string platform, string serviceType)
    signal createShortcut(string productId, string platform, string serviceType, string gameName)
    
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
    
    function getProductId() {
        if (!gameData) return "";
        if (gameData.id) return gameData.id; // PSNOW
        if (gameData.productId) return gameData.productId; // PS5 Cloud catalog
        if (gameData.product_id) return gameData.product_id; // Owned games
        return "";
    }
    
    // ============================================================================
    // DEBUG: Temporary logging helper - REMOVE AFTER DEBUGGING
    // ============================================================================
    // Get a short identifier for logging (game name or product ID)
    function getLogId() {
        let name = getGameName();
        let id = getProductId();
        if (name && name !== "Unknown Game") {
            return name.substring(0, 20) + (id ? " [" + id.substring(0, 10) + "]" : "");
        }
        return id ? id.substring(0, 20) : "unknown";
    }
    // ============================================================================
    
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
            // ============================================================================
            // DEBUG: Extensive logging - REMOVE AFTER DEBUGGING
            // ============================================================================
            let logId = getLogId();
            console.log("[CloudGameCard:" + logId + "] PSCloud: Checking gameData for images...");
            let imageUrlStr = gameData.imageUrl ? (typeof gameData.imageUrl === 'string' ? gameData.imageUrl : gameData.imageUrl.toString()) : "";
            console.log("[CloudGameCard:" + logId + "] PSCloud: gameData.imageUrl =", imageUrlStr ? (imageUrlStr.length > 50 ? imageUrlStr.substring(0, 50) + "..." : imageUrlStr) : "undefined");
            console.log("[CloudGameCard:" + logId + "] PSCloud: gameData.images =", gameData.images ? (Array.isArray(gameData.images) ? "array[" + gameData.images.length + "]" : typeof gameData.images) : "undefined");
            // ============================================================================
            
            if (gameData.imageUrl) {
                let url = typeof gameData.imageUrl === 'string' ? gameData.imageUrl : gameData.imageUrl.toString();
                // DEBUG: Remove this log
                console.log("[CloudGameCard:" + logId + "] PSCloud: Returning imageUrl:", url.length > 50 ? url.substring(0, 50) + "..." : url);
                return url;
            }
            if (gameData.images && Array.isArray(gameData.images) && gameData.images.length > 0) {
                // DEBUG: Remove this log
                console.log("[CloudGameCard:" + logId + "] PSCloud: Checking images array, length:", gameData.images.length);
                // Prefer cover (type 10) over landscape (type 12/13)
                for (let i = 0; i < gameData.images.length; i++) {
                    let img = gameData.images[i];
                    if (img && img.url && img.type === 10) {
                        let url = typeof img.url === 'string' ? img.url : img.url.toString();
                        // DEBUG: Remove this log
                        console.log("[CloudGameCard:" + logId + "] PSCloud: Found type 10 (cover):", url.length > 50 ? url.substring(0, 50) + "..." : url);
                        return url;
                    }
                }
                // Fallback to landscape if no cover
                for (let i = 0; i < gameData.images.length; i++) {
                    let img = gameData.images[i];
                    if (img && img.url && (img.type === 12 || img.type === 13)) {
                        let url = typeof img.url === 'string' ? img.url : img.url.toString();
                        // DEBUG: Remove this log
                        console.log("[CloudGameCard:" + logId + "] PSCloud: Found type", img.type, "(landscape):", url.length > 50 ? url.substring(0, 50) + "..." : url);
                        return url;
                    }
                }
                // Last resort: any image
                for (let i = 0; i < gameData.images.length; i++) {
                    let img = gameData.images[i];
                    if (img && img.url) {
                        let url = typeof img.url === 'string' ? img.url : img.url.toString();
                        // DEBUG: Remove this log
                        console.log("[CloudGameCard:" + logId + "] PSCloud: Found any image:", url.length > 50 ? url.substring(0, 50) + "..." : url);
                        return url;
                    }
                }
                // DEBUG: Remove this log
                console.log("[CloudGameCard:" + logId + "] PSCloud: No valid image URL found in images array");
            } else {
                // DEBUG: Remove this log
                console.log("[CloudGameCard:" + logId + "] PSCloud: No images array or array is empty");
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
    
    // ============================================================================
    // TEMPORARY: Flag to prevent infinite loops - EVALUATE IF STILL NEEDED
    // ============================================================================
    property bool updatingImage: false
    
    // ============================================================================
    // DEBUG: Watch for gameData changes with extensive logging - REMOVE LOGS AFTER DEBUGGING
    // NOTE: The handler itself might be needed, but remove all console.log calls
    // ============================================================================
    // Watch for gameData changes - images might be added after component creation
    onGameDataChanged: {
        // Prevent infinite loops
        if (updatingImage) {
            return;
        }
        
        // DEBUG: Remove this log
        let logId = getLogId();
        console.log("[CloudGameCard:" + logId + "] gameData changed, checking for images...");
        // Delay to ensure gameData is fully populated
        // Capture 'card' reference to ensure context is preserved
        let cardRef = card;
        Qt.callLater(function() {
            if (!cardRef) return;
            let url = cardRef.getImageUrl();
            if (url) {
                let urlStr = typeof url === 'string' ? url : url.toString();
                // Only update if URL actually changed
                if (urlStr !== cardRef.cachedImageUrl && urlStr !== "") {
                    // DEBUG: Remove this log
                    console.log("[CloudGameCard:" + logId + "] gameData changed: Found new image URL:", urlStr.length > 50 ? urlStr.substring(0, 50) + "..." : urlStr);
                    cardRef.updatingImage = true;
                    cardRef.cachedImageUrl = urlStr;
                    cardRef.updatingImage = false;
                }
            }
        });
    }
    // ============================================================================
    
    // Load image URL on component creation - ONLY from catalog/entitlement data, no API calls
    Component.onCompleted: {
        // Delay setting image URL to ensure Image component is ready
        // This fixes race condition where Image component isn't ready when source is set
        // Use Timer instead of Qt.callLater for more reliable timing
        imageLoadTimer.start();
        // For PSNOW games without images in catalog, show placeholder until shortcut is clicked
        // Game details will be fetched only when shortcut button is pressed
        // For PS5 Cloud games, images should come from the entitlements API response
    }
    
    // ============================================================================
    // TEMPORARY: Timer to delay image URL setting - EVALUATE IF STILL NEEDED AFTER DEBUGGING
    // This was added to fix race condition where Image component isn't ready when source is set
    // ============================================================================
    // Timer to delay image URL setting until Image component is ready
    Timer {
        id: imageLoadTimer
        interval: 100  // Delay to ensure Image component is fully initialized and visible
        repeat: false
        running: false  // Only start when explicitly called
        onTriggered: {
            // DEBUG: Remove all console.log calls below
            let logId = getLogId();
            // Only set URL if component is visible (component might be in a ListView/GridView that's not visible yet)
            if (!card.visible) {
                console.log("[CloudGameCard:" + logId + "] Component not visible yet, retrying in 50ms...");
                imageLoadRetryTimer.start();
                return;
            }
            
            // Don't run if already updating
            if (updatingImage) {
                console.log("[CloudGameCard:" + logId + "] Timer: Already updating image, skipping");
                return;
            }
            
            let initialUrl = getImageUrl();
            let urlStr = initialUrl ? (typeof initialUrl === 'string' ? initialUrl : initialUrl.toString()) : "";
            console.log("[CloudGameCard:" + logId + "] Timer triggered: getImageUrl() returned:", urlStr ? (urlStr.length > 50 ? urlStr.substring(0, 50) + "..." : urlStr) : "empty");
            
            // Only set if we have a URL and it's different from current
            if (urlStr && urlStr !== "" && urlStr !== cachedImageUrl) {
                updatingImage = true;
                cachedImageUrl = urlStr;
                console.log("[CloudGameCard:" + logId + "] Set cachedImageUrl to:", urlStr.length > 50 ? urlStr.substring(0, 50) + "..." : urlStr);
                updatingImage = false;
            } else if (!urlStr || urlStr === "") {
                console.log("[CloudGameCard:" + logId + "] No initial image URL available");
            } else {
                console.log("[CloudGameCard:" + logId + "] Image URL already set, skipping");
            }
        }
    }
    // ============================================================================
    
    // ============================================================================
    // TEMPORARY: Retry timer - EVALUATE IF STILL NEEDED AFTER DEBUGGING
    // ============================================================================
    // Retry timer if component isn't visible yet
    Timer {
        id: imageLoadRetryTimer
        interval: 50
        repeat: false
        onTriggered: {
            // DEBUG: Remove all console.log calls below
            let logId = getLogId();
            if (card.visible) {
                let initialUrl = getImageUrl();
                let urlStr = initialUrl ? (typeof initialUrl === 'string' ? initialUrl : initialUrl.toString()) : "";
                console.log("[CloudGameCard:" + logId + "] Retry: getImageUrl() returned:", urlStr ? (urlStr.length > 50 ? urlStr.substring(0, 50) + "..." : urlStr) : "empty");
                if (initialUrl && initialUrl !== "" && urlStr !== cachedImageUrl) {
                    updatingImage = true;
                    cachedImageUrl = urlStr;
                    console.log("[CloudGameCard:" + logId + "] Retry: Set cachedImageUrl to:", urlStr.length > 50 ? urlStr.substring(0, 50) + "..." : urlStr);
                    updatingImage = false;
                }
            } else {
                console.log("[CloudGameCard:" + logId + "] Component still not visible, giving up");
            }
        }
    }
    // ============================================================================
    
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
        anchors.margins: 12
        spacing: 8
        
        // Game Image
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 120
            color: "#1a1a1a"
            radius: 4
            
            Image {
                id: gameImage
                anchors.fill: parent
                anchors.margins: 1
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: true
                smooth: true
                
                // Always bind to cachedImageUrl - will update when URL is set
                // Only set source if cachedImageUrl is non-empty to avoid loading empty string
                source: cachedImageUrl && cachedImageUrl !== "" ? cachedImageUrl : ""
                
                // ============================================================================
                // DEBUG: Image loading status logging - REMOVE AFTER DEBUGGING
                // ============================================================================
                // Log image loading status for debugging
                onStatusChanged: {
                    let logId = getLogId();
                    let sourceStr = source ? (typeof source === 'string' ? source : source.toString()) : "";
                    if (status === Image.Loading) {
                        console.log("[CloudGameCard:" + logId + "] Image loading:", sourceStr ? (sourceStr.length > 50 ? sourceStr.substring(0, 50) + "..." : sourceStr) : "empty source");
                    } else if (status === Image.Ready) {
                        console.log("[CloudGameCard:" + logId + "] Image ready:", sourceStr ? (sourceStr.length > 50 ? sourceStr.substring(0, 50) + "..." : sourceStr) : "empty source");
                    } else if (status === Image.Error) {
                        console.warn("[CloudGameCard:" + logId + "] Image error:", sourceStr ? (sourceStr.length > 50 ? sourceStr.substring(0, 50) + "..." : sourceStr) : "empty source", "error:", sourceSize);
                    }
                }
                
                // Also log when source changes
                onSourceChanged: {
                    let logId = getLogId();
                    let sourceStr = source ? (typeof source === 'string' ? source : source.toString()) : "";
                    console.log("[CloudGameCard:" + logId + "] Image source changed to:", sourceStr ? (sourceStr.length > 50 ? sourceStr.substring(0, 50) + "..." : sourceStr) : "empty");
                }
                // ============================================================================
                
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
        }
        
        // Game Title
        Label {
            Layout.fillWidth: true
            Layout.preferredHeight: implicitHeight
            text: getGameName()
            font.pixelSize: 16
            font.bold: true
            elide: Text.ElideRight
            maximumLineCount: 2
            wrapMode: Text.Wrap
        }
        
        // Platform Badge
        Label {
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? implicitHeight : 0
            text: getPlatformBadge()
            font.pixelSize: 12
            font.weight: Font.Medium
            color: "#FFD700"
            visible: getPlatformBadge() !== ""
        }
        
        // Action Buttons - fixed size to always fit
        ColumnLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 84  // 40 (stream) + 36 (shortcut) + 8 (spacing)
            spacing: 8
            visible: true
            
            // Stream Game button
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                Layout.minimumHeight: 40
                Layout.maximumHeight: 40
                radius: 6
                color: streamMouseArea.containsMouse ? Qt.lighter(Material.accent, 1.2) : Material.accent
                
                Behavior on color { ColorAnimation { duration: 150 } }
                
                MouseArea {
                    id: streamMouseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    
                    onClicked: {
                        let productId = getProductId();
                        let platform = getPlatform();
                        let serviceType = getServiceType();
                        if (productId !== "") {
                            // For PSCloud, use entitlement ID, for PSNOW use productId
                            let streamingId = isPsnow ? productId : (gameData && gameData.id ? gameData.id : productId);
                            streamGame(streamingId, platform, serviceType);
                        }
                    }
                }
                
                Label {
                    anchors.centerIn: parent
                    text: qsTr("Stream Game")
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    color: "white"
                }
            }
            
            // Shortcut button with Square/X icon
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 36
                Layout.minimumHeight: 36
                Layout.maximumHeight: 36
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
                            let productId = getProductId();
                            let platform = getPlatform();
                            let serviceType = getServiceType();
                            let gameName = getGameName();
                            if (productId !== "") {
                                // Fetch game details (including landscape image) when shortcut is pressed
                                Chiaki.cloudCatalog.fetchGameDetails(productId, function(success, message, jsonData) {
                                    if (success && jsonData) {
                                        try {
                                            let details = JSON.parse(jsonData);
                                            // Update gameData with fetched details (especially landscape image)
                                            if (details.extracted_images) {
                                                // Merge extracted images into gameData
                                                if (!gameData.extracted_images) {
                                                    gameData.extracted_images = {};
                                                }
                                                if (details.extracted_images.landscape) {
                                                    gameData.extracted_images.landscape = details.extracted_images.landscape;
                                                    // DEBUG: Remove this log
                                                    let logId = getLogId();
                                                    let landscapeUrl = typeof details.extracted_images.landscape === 'string' ? details.extracted_images.landscape : details.extracted_images.landscape.toString();
                                                    console.log("[CloudGameCard:" + logId + "] Shortcut button: Setting landscape image:", landscapeUrl.length > 50 ? landscapeUrl.substring(0, 50) + "..." : landscapeUrl);
                                                    cachedImageUrl = details.extracted_images.landscape;
                                                }
                                                if (details.extracted_images.cover) {
                                                    gameData.extracted_images.cover = details.extracted_images.cover;
                                                }
                                            }
                                            // Now create shortcut with full details
                                            createShortcut(productId, platform, serviceType, gameName);
                                        } catch (e) {
                                            console.error("Failed to parse game details:", e);
                                            // Still create shortcut even if details parsing fails
                                            createShortcut(productId, platform, serviceType, gameName);
                                        }
                                    } else {
                                        console.error("Failed to fetch game details:", message);
                                        // Still create shortcut even if details fetch fails
                                        createShortcut(productId, platform, serviceType, gameName);
                                    }
                                });
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
        // Cross/A button (Enter/Space) - Stream game
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Space || event.key === Qt.Key_Enter) {
            let productId = getProductId();
            let platform = getPlatform();
            let serviceType = getServiceType();
            if (productId !== "") {
                streamGame(productId, platform, serviceType);
                event.accepted = true;
            }
        }
        // Square/X button (X key) - Create shortcut
        else if (event.key === Qt.Key_X) {
            let productId = getProductId();
            let platform = getPlatform();
            let serviceType = getServiceType();
            let gameName = getGameName();
            if (productId !== "") {
                createShortcut(productId, platform, serviceType, gameName);
                event.accepted = true;
            }
        }
    }
}


