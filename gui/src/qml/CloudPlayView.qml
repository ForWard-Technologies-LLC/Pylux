import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Effects

import org.streetpea.chiaking

import "controls" as C

Pane {
    id: root
    padding: 0
    
    property var mainTabBar: null
    property var settingsButton: null
    property var showConfirmDialogFunc: null
    
    // Expose child components for navigation
    readonly property Item catalogButtonItem: searchContainer
    readonly property Item searchContainerItem: searchContainer
    readonly property Item refreshButtonItem: refreshButton
    
    property var allGames: []
    property var filteredGames: []
    property var currentPageGames: []
    property bool isLoading: false
    property string searchQuery: ""
    property string authErrorMessage: ""
    property string fallbackRegion: ""
    property bool catalogNativeMode: true
    property var activeTagFilters: [] // empty = show all; values: owned, streamable, purchaseable
    property bool showFavoritesOnly: false
    property int sortState: 0 // 0=Playable First, 1=A-Z, 2=Z-A
    property var favoriteProductIds: []
    property var qrCodeDialogRef: null

    readonly property var tagFilterCategories: ["owned", "streamable", "purchaseable"]
    readonly property var tagFilterLabels: [qsTr("Owned"), qsTr("Streamable"), qsTr("Store")]
    
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
        fallbackRegion = Chiaki.settings.cloudResolvedStoreCountry || "";
        catalogNativeMode = Chiaki.settings.cloudCatalogNativeMode;
        sortState = Chiaki.settings.cloudSortState || 0;
        let savedTagFilters = Chiaki.settings.cloudTagFilters;
        if (savedTagFilters) {
            try {
                let parsed = JSON.parse(savedTagFilters);
                if (Array.isArray(parsed))
                    activeTagFilters = parsed;
            } catch (e) {
                console.warn("Failed to parse cloud tag filters:", e);
            }
        }
        let savedFavorites = Chiaki.settings.cloudFavorites;
        if (savedFavorites) {
            try {
                favoriteProductIds = JSON.parse(savedFavorites);
            } catch (e) {
                console.error("Failed to parse saved favorites:", e);
                favoriteProductIds = [];
            }
        }
        Qt.callLater(() => loadUnifiedCatalog());
        initialFocusTimer.restart();
    }
    
    onVisibleChanged: {
        if (visible) {
            if (allGames.length === 0)
                loadUnifiedCatalog();
            initialFocusTimer.restart();
        }
    }
    
    StackView.onActivated: {
        Qt.callLater(() => loadUnifiedCatalog());
        initialFocusTimer.restart();
    }

    // Account/profile switch, NPSSO change, or cloud-language change wipes the catalog cache in the
    // backend; reload here so the visible grid never keeps showing the previous account's games.
    Connections {
        target: Chiaki.cloudCatalog
        function onCacheInvalidated() {
            loadUnifiedCatalog();
        }
    }

    // Pins default focus to the first game card (or the filter toggle if games
    // haven't loaded yet) after startup focus churn settles, so the search field
    // never holds focus by default. Runs late enough to override the window's
    // initial active-focus assignment.
    Timer {
        id: initialFocusTimer
        interval: 150
        repeat: false
        onTriggered: {
            if (gamesGrid.count > 0) {
                gamesGrid.currentIndex = 0;
                gamesGrid.forceActiveFocus();
            } else {
                filterToggle.forceActiveFocus();
            }
        }
    }
    
    // Handle Escape/B button for quit confirmation dialog
    Keys.onEscapePressed: {
        if (showConfirmDialogFunc) {
            showConfirmDialogFunc(qsTr("Quit"), qsTr("Are you sure you want to quit?"), () => Qt.quit(), null, true);
        }
    }
    
    // Handle RB/LB navigation for section switching
    Keys.onPressed: (event) => {
        if (event.modifiers)
            return;
        
        // Handle B button (Back key) for quit confirmation dialog
        if (event.key === Qt.Key_Back) {
            if (showConfirmDialogFunc) {
                showConfirmDialogFunc(qsTr("Quit"), qsTr("Are you sure you want to quit?"), () => Qt.quit(), null, true);
            }
            event.accepted = true;
            return;
        }
        
    }

    function tagFilterSummary() {
        if (!activeTagFilters || activeTagFilters.length === 0)
            return qsTr("All games");
        let labels = [];
        for (let i = 0; i < tagFilterCategories.length; i++) {
            if (activeTagFilters.indexOf(tagFilterCategories[i]) !== -1)
                labels.push(tagFilterLabels[i]);
        }
        return labels.length > 0 ? labels.join(" · ") : qsTr("All games");
    }

    function isTagFilterActive(tag) {
        return !activeTagFilters || activeTagFilters.length === 0
               || activeTagFilters.indexOf(tag) !== -1;
    }

    function setTagFilters(tags) {
        activeTagFilters = tags;
        Chiaki.settings.cloudTagFilters = JSON.stringify(tags);
        applySearchFilter();
    }

    function toggleTagFilter(tag) {
        // Empty active set means "all selected", so start from every category and remove from there.
        let current = (!activeTagFilters || activeTagFilters.length === 0)
                      ? tagFilterCategories.slice()
                      : activeTagFilters.slice();
        let idx = current.indexOf(tag);
        if (idx !== -1)
            current.splice(idx, 1);
        else
            current.push(tag);
        if (current.length === 0 || current.length === tagFilterCategories.length)
            setTagFilters([]);
        else
            setTagFilters(current);
    }

    function isPlayableNow(game) {
        return game && game.category !== "purchaseable";
    }

    function sortGames(games) {
        let sorted = games.slice();
        if (sortState === 1) {
            sorted.sort((a, b) => gameName(a).localeCompare(gameName(b)));
        } else if (sortState === 2) {
            sorted.sort((a, b) => gameName(b).localeCompare(gameName(a)));
        } else {
            sorted.sort((a, b) => {
                let pa = isPlayableNow(a) ? 1 : 0;
                let pb = isPlayableNow(b) ? 1 : 0;
                if (pa !== pb) return pb - pa;
                return gameName(a).localeCompare(gameName(b));
            });
        }
        return sorted;
    }

    function gameName(game) {
        if (!game) return "";
        if (game.name) return game.name;
        if (game.game_meta && game.game_meta.name) return game.game_meta.name;
        return "";
    }

    function loadUnifiedCatalog() {
        let npssoToken = Chiaki.settings.psnNpssoToken;
        if (!npssoToken || npssoToken.trim().length === 0) {
            authErrorMessage = qsTr("NPSSO token is required for cloud games. Please login and enter a valid NPSSO token. You also need a valid PS Plus subscription.");
        } else {
            authErrorMessage = "";
        }

        // The grid is about to be emptied. If it currently holds focus, its cards
        // vanish and the (now empty) grid swallows arrow keys, leaving focus
        // black-holed. Park focus on the filter toggle so the header stays
        // navigable while loading; the post-load callback restores it to the
        // first card once games are back.
        if (gamesGrid.activeFocus)
            filterToggle.forceActiveFocus();

        allGames = [];
        filteredGames = [];
        currentPageGames = [];
        isLoading = true;

        Chiaki.cloudCatalog.fetchUnifiedCatalog(function(success, message, jsonData) {
            isLoading = false;
            if (!success || !jsonData) {
                allGames = [];
                filteredGames = [];
                currentPageGames = [];
                showErrorToast(qsTr("API Error"), message || qsTr("Failed to fetch game catalog"));
                return;
            }
            try {
                let data = JSON.parse(jsonData);
                if (data.games && Array.isArray(data.games)) {
                    allGames = data.games;
                    fallbackRegion = data.fallbackRegion || "";
                    catalogNativeMode = data.nativeMode !== false;
                    Chiaki.settings.cloudResolvedStoreCountry = fallbackRegion;
                    Chiaki.settings.cloudCatalogNativeMode = catalogNativeMode;
                    if (data.warning)
                        authErrorMessage = data.warning;
                    else if (npssoToken && npssoToken.trim().length > 0)
                        authErrorMessage = "";
                    if (message && message !== "Success" && message !== "Cached")
                        showErrorToast(qsTr("Partial Catalog"), message);
                    applySearchFilter();
                    Qt.callLater(() => {
                        if (gamesGrid.count > 0
                                && !searchField.activeFocus
                                && !tagFilterPopup.opened) {
                            gamesGrid.currentIndex = 0;
                            gamesGrid.forceActiveFocus();
                        }
                    });
                } else {
                    showErrorToast(qsTr("Error"), qsTr("No games found in catalog"));
                }
            } catch (e) {
                console.error("Failed to parse unified catalog:", e);
                showErrorToast(qsTr("Parse Error"), qsTr("Failed to parse catalog data: %1").arg(e.toString()));
            }
        });
    }

    function applySearchFilter() {
        let hadFocus = searchField && searchField.activeFocus;
        
        let gamesToFilter = allGames.slice();

        if (activeTagFilters && activeTagFilters.length > 0) {
            gamesToFilter = gamesToFilter.filter(function(game) {
                return game.category && activeTagFilters.indexOf(game.category) !== -1;
            });
        }

        if (showFavoritesOnly) {
            gamesToFilter = gamesToFilter.filter(function(game) {
                let productId = game.productId || game.product_id || game.id;
                return favoriteProductIds.indexOf(productId) !== -1;
            });
        }

        if (searchQuery && searchQuery.trim() !== "") {
            let query = searchQuery.toLowerCase().trim();
            gamesToFilter = gamesToFilter.filter(function(game) {
                let name = gameName(game).toLowerCase();
                let pid = (game.productId || game.product_id || "").toLowerCase();
                return name.includes(query) || pid.includes(query);
            });
        }

        filteredGames = sortGames(gamesToFilter);
        currentPageGames = filteredGames.slice();
        
        // If user was typing, restore focus immediately after model update
        if (hadFocus) {
            Qt.callLater(() => {
                if (searchField) {
                    searchField.forceActiveFocus();
                }
            });
        }
    }
    
    function toggleFavorite(productId) {
        if (!productId) return;
        
        let index = favoriteProductIds.indexOf(productId);
        let newFavorites = favoriteProductIds.slice(); // Create a new array
        
        if (index !== -1) {
            // Remove from favorites
            newFavorites.splice(index, 1);
        } else {
            // Add to favorites
            newFavorites.push(productId);
        }
        
        // Assign the new array to trigger property change notification
        favoriteProductIds = newFavorites;
        
        // Save to settings
        Chiaki.settings.cloudFavorites = JSON.stringify(favoriteProductIds);
        
        // Re-apply filter to update view
        applySearchFilter();
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
        height: 52
        
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
                topMargin: 6
                bottomMargin: 6
            }
            spacing: 8

            // Acquisition-tag filter summary (Owned / Streamable / Store) — far left
            Item {
                id: filterToggle
                Layout.preferredWidth: Math.max(filterToggleRow.implicitWidth + 20, 110)
                Layout.preferredHeight: 36

                Rectangle {
                    anchors.fill: parent
                    color: filterToggle.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.15) : "transparent"
                    border.color: filterToggle.activeFocus ? "#00d4ff" : "transparent"
                    border.width: filterToggle.activeFocus ? 1 : 0
                    radius: 4
                }

                Row {
                    id: filterToggleRow
                    anchors.centerIn: parent
                    spacing: 6
                    property bool filtersActive: activeTagFilters && activeTagFilters.length > 0
                    property color tint: filtersActive ? "#00d4ff" : Qt.rgba(255, 255, 255, 0.6)

                    // Funnel / "decrease" filter glyph (matches iOS line.3.horizontal.decrease)
                    Canvas {
                        id: filterGlyph
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16; height: 16
                        property color stroke: filterToggleRow.tint
                        onStrokeChanged: requestPaint()
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.reset();
                            ctx.strokeStyle = stroke;
                            ctx.lineWidth = 1.8; ctx.lineCap = "round";
                            ctx.beginPath();
                            ctx.moveTo(2, 4); ctx.lineTo(14, 4);
                            ctx.moveTo(4, 8); ctx.lineTo(12, 8);
                            ctx.moveTo(6, 12); ctx.lineTo(10, 12);
                            ctx.stroke();
                        }
                    }

                    Text {
                        id: filterToggleText
                        anchors.verticalCenter: parent.verticalCenter
                        text: tagFilterSummary()
                        font.pixelSize: 13
                        font.weight: Font.Medium
                        color: filterToggleRow.tint
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: tagFilterPopup.open()
                }

                focusPolicy: Qt.StrongFocus
                KeyNavigation.left: sortToggle
                KeyNavigation.right: searchContainer
                KeyNavigation.down: gamesGrid.count > 0 ? gamesGrid : null
                KeyNavigation.up: mainTabBar ? mainTabBar.itemAt(1) : null
                Keys.onReturnPressed: { tagFilterPopup.open(); event.accepted = true; }
            }

            // Flexible gap pushes search + the right-side controls to the right edge.
            // It sits to the LEFT of search so the field expands leftward into this gap.
            Item { Layout.fillWidth: true }

            // Search bar - icon that expands leftward when focused (right side, left of favorites)
            Rectangle {
                id: searchContainer
                Layout.preferredHeight: 36
                Layout.preferredWidth: searchContainer.activeFocus || searchField.activeFocus || searchField.text.length > 0 ? 360 : 36
                radius: 18
                color: searchContainer.activeFocus || searchField.activeFocus ? Qt.rgba(255, 255, 255, 0.15) : Qt.rgba(255, 255, 255, 0.1)
                border.color: searchContainer.activeFocus || searchField.activeFocus ? "#00d4ff" : Qt.rgba(255, 255, 255, 0.2)
                border.width: searchContainer.activeFocus || searchField.activeFocus ? 2 : 1
                focusPolicy: Qt.StrongFocus
                // Keep search OUT of the automatic focus chain so it never grabs default
                // focus on launch. It's still reachable by click and arrow/controller nav.
                activeFocusOnTab: false
                
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
                    // Filter toggle sits to the left of search now
                    filterToggle.forceActiveFocus();
                    event.accepted = true;
                }
                
                Keys.onRightPressed: {
                    favoritesToggle.forceActiveFocus();
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
                        // Not auto-focusable on launch; only via click / explicit navigation.
                        activeFocusOnTab: false
                        verticalAlignment: TextInput.AlignVCenter
                        topPadding: 0
                        bottomPadding: 0
                        background: Rectangle {
                            color: "transparent"
                        }
                        
                        Behavior on opacity {
                            NumberAnimation { duration: 200 }
                        }
                        
                        KeyNavigation.right: favoritesToggle
                        KeyNavigation.left: filterToggle
                        KeyNavigation.down: gamesGrid.count > 0 ? gamesGrid : null
                        
                        KeyNavigation.up: mainTabBar ? mainTabBar.itemAt(1) : null
                        
                        Keys.onLeftPressed: (event) => {
                            filterToggle.forceActiveFocus();
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
                        }
                        
                        Keys.onEscapePressed: {
                            text = "";
                            searchQuery = "";
                            focus = false;
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
            
            // Right side controls
            RowLayout {
                spacing: 0
                
                // Filter dialog: mirrors the proven ConfirmDialog pattern (overlay-parented,
                // root-centered, content-sized) so it centers correctly and captures input.
                Dialog {
                    id: tagFilterPopup
                    parent: Overlay.overlay
                    x: Math.round((root.width - width) / 2)
                    y: Math.round((root.height - height) / 2)
                    width: 320
                    modal: true
                    focus: true
                    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                    title: qsTr("Filter games")
                    Material.roundedScale: Material.MediumScale

                    Component.onCompleted: {
                        header.horizontalAlignment = Text.AlignHCenter;
                        // Qt 6.6: workaround dialog header background flashing transparent on close.
                        header.background = null;
                    }

                    background: Rectangle {
                        color: Qt.rgba(10/255, 20/255, 38/255, 0.98)
                        radius: 12
                        border.color: "#00d4ff"
                        border.width: 2
                    }

                    // Sync checkbox visuals to current state on open, then capture focus so the
                    // grid behind never receives our Enter / confirm key.
                    onOpened: {
                        ownedCheck.checked = isTagFilterActive(tagFilterCategories[0]);
                        streamableCheck.checked = isTagFilterActive(tagFilterCategories[1]);
                        storeCheck.checked = isTagFilterActive(tagFilterCategories[2]);
                        ownedCheck.forceActiveFocus(Qt.TabFocusReason);
                    }
                    onClosed: filterToggle.forceActiveFocus()

                    ColumnLayout {
                        spacing: 10

                        CheckBox {
                            id: ownedCheck
                            text: tagFilterLabels[0]
                            Layout.fillWidth: true
                            focusPolicy: Qt.StrongFocus
                            onClicked: toggleTagFilter(tagFilterCategories[0])
                            KeyNavigation.down: streamableCheck
                            Keys.onReturnPressed: { toggle(); toggleTagFilter(tagFilterCategories[0]); event.accepted = true; }
                        }
                        CheckBox {
                            id: streamableCheck
                            text: tagFilterLabels[1]
                            Layout.fillWidth: true
                            focusPolicy: Qt.StrongFocus
                            onClicked: toggleTagFilter(tagFilterCategories[1])
                            KeyNavigation.up: ownedCheck
                            KeyNavigation.down: storeCheck
                            Keys.onReturnPressed: { toggle(); toggleTagFilter(tagFilterCategories[1]); event.accepted = true; }
                        }
                        CheckBox {
                            id: storeCheck
                            text: tagFilterLabels[2]
                            Layout.fillWidth: true
                            focusPolicy: Qt.StrongFocus
                            onClicked: toggleTagFilter(tagFilterCategories[2])
                            KeyNavigation.up: streamableCheck
                            KeyNavigation.down: showAllButton
                            Keys.onReturnPressed: { toggle(); toggleTagFilter(tagFilterCategories[2]); event.accepted = true; }
                        }
                        RowLayout {
                            Layout.alignment: Qt.AlignCenter
                            Layout.topMargin: 6
                            spacing: 12
                            Button {
                                id: showAllButton
                                text: qsTr("Show all")
                                focusPolicy: Qt.StrongFocus
                                Material.roundedScale: Material.SmallScale
                                onClicked: {
                                    setTagFilters([]);
                                    ownedCheck.checked = true;
                                    streamableCheck.checked = true;
                                    storeCheck.checked = true;
                                    tagFilterPopup.close();
                                }
                                KeyNavigation.up: storeCheck
                                KeyNavigation.right: closeButton
                                Keys.onReturnPressed: { clicked(); event.accepted = true; }
                            }
                            Button {
                                id: closeButton
                                text: qsTr("Close")
                                focusPolicy: Qt.StrongFocus
                                Material.roundedScale: Material.SmallScale
                                onClicked: tagFilterPopup.close()
                                KeyNavigation.up: storeCheck
                                KeyNavigation.left: showAllButton
                                Keys.onReturnPressed: { clicked(); event.accepted = true; }
                            }
                        }
                    }
                }

                // Favorites filter toggle
                Item {
                    id: favoritesToggle
                    Layout.preferredWidth: 36
                    Layout.preferredHeight: 36
                    Layout.rightMargin: 8

                    Rectangle {
                        anchors.fill: parent
                        color: favoritesToggle.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.15) : "transparent"
                        border.color: favoritesToggle.activeFocus ? "#00d4ff" : "transparent"
                        border.width: favoritesToggle.activeFocus ? 1 : 0
                        radius: 4
                    }

                    // Star glyph: filled gold when favorites-only is active, outline otherwise
                    Canvas {
                        id: favoritesStar
                        anchors.centerIn: parent
                        width: 20; height: 20
                        property bool active: showFavoritesOnly
                        onActiveChanged: requestPaint()
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.reset();
                            var cx = 10, cy = 10.5, spikes = 5, outer = 8.5, inner = 3.6;
                            var rot = -Math.PI / 2;
                            var step = Math.PI / spikes;
                            ctx.beginPath();
                            ctx.moveTo(cx + Math.cos(rot) * outer, cy + Math.sin(rot) * outer);
                            for (var i = 0; i < spikes; i++) {
                                rot += step;
                                ctx.lineTo(cx + Math.cos(rot) * inner, cy + Math.sin(rot) * inner);
                                rot += step;
                                ctx.lineTo(cx + Math.cos(rot) * outer, cy + Math.sin(rot) * outer);
                            }
                            ctx.closePath();
                            if (active) {
                                ctx.fillStyle = "#FFD700";
                                ctx.fill();
                            } else {
                                ctx.strokeStyle = Qt.rgba(255, 255, 255, 0.7);
                                ctx.lineWidth = 1.6;
                                ctx.lineJoin = "round";
                                ctx.stroke();
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { showFavoritesOnly = !showFavoritesOnly; applySearchFilter(); }
                    }

                    focusPolicy: Qt.StrongFocus
                    KeyNavigation.left: searchContainer
                    KeyNavigation.right: refreshButton
                    KeyNavigation.down: gamesGrid.count > 0 ? gamesGrid : null
                    KeyNavigation.up: mainTabBar ? mainTabBar.itemAt(1) : null
                    Keys.onReturnPressed: { showFavoritesOnly = !showFavoritesOnly; applySearchFilter(); event.accepted = true; }
                }

                // Refresh button (icon-only, matches Android/iOS) — plain Item so the
                // bundled Material SVG renders at full size, uniform with the star/sort glyphs.
                Item {
                    id: refreshButton
                    Layout.preferredWidth: 36
                    Layout.preferredHeight: 36
                    Layout.rightMargin: 8
                    enabled: !isLoading

                    function activate() {
                        if (!enabled)
                            return;
                        // invalidateCache() emits cacheInvalidated, which triggers the reload above.
                        Chiaki.cloudCatalog.invalidateCache();
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: refreshButton.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.15) : "transparent"
                        border.color: refreshButton.activeFocus ? "#00d4ff" : "transparent"
                        border.width: refreshButton.activeFocus ? 1 : 0
                        radius: 4
                    }

                    Image {
                        anchors.centerIn: parent
                        source: "qrc:/icons/refresh-24px.svg"
                        sourceSize: Qt.size(48, 48)
                        width: 24
                        height: 24
                        smooth: true
                        opacity: refreshButton.enabled ? 1.0 : 0.4
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: refreshButton.activate()
                    }

                    focusPolicy: Qt.StrongFocus
                    KeyNavigation.left: favoritesToggle
                    KeyNavigation.right: sortToggle
                    KeyNavigation.down: gamesGrid.count > 0 ? gamesGrid : null
                    KeyNavigation.up: mainTabBar ? mainTabBar.itemAt(1) : null
                    Keys.onReturnPressed: { activate(); event.accepted = true; }
                }

                // Sort toggle (far right, just before the game count)
                Item {
                    id: sortToggle
                    Layout.preferredWidth: sortToggleRow.implicitWidth + 16
                    Layout.preferredHeight: 36
                    Layout.rightMargin: 8

                    Rectangle {
                        anchors.fill: parent
                        color: sortToggle.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.15) : "transparent"
                        border.color: sortToggle.activeFocus ? "#00d4ff" : "transparent"
                        border.width: sortToggle.activeFocus ? 1 : 0
                        radius: 4
                    }

                    Row {
                        id: sortToggleRow
                        anchors.centerIn: parent
                        spacing: 5

                        // Up/down arrows glyph (matches iOS arrow.up.arrow.down)
                        Canvas {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18; height: 18
                            onPaint: {
                                var ctx = getContext("2d");
                                ctx.reset();
                                ctx.strokeStyle = "#00d4ff";
                                ctx.lineWidth = 1.8; ctx.lineCap = "round"; ctx.lineJoin = "round";
                                ctx.beginPath();
                                ctx.moveTo(5, 15); ctx.lineTo(5, 3);
                                ctx.moveTo(2, 6); ctx.lineTo(5, 3); ctx.lineTo(8, 6);
                                ctx.stroke();
                                ctx.beginPath();
                                ctx.moveTo(13, 3); ctx.lineTo(13, 15);
                                ctx.moveTo(10, 12); ctx.lineTo(13, 15); ctx.lineTo(16, 12);
                                ctx.stroke();
                            }
                        }

                        Text {
                            id: sortToggleText
                            anchors.verticalCenter: parent.verticalCenter
                            text: sortState === 1 ? qsTr("A → Z") : (sortState === 2 ? qsTr("Z → A") : qsTr("Playable"))
                            font.pixelSize: 13
                            font.weight: Font.Medium
                            color: "#00d4ff"
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            sortState = (sortState + 1) % 3;
                            Chiaki.settings.cloudSortState = sortState;
                            applySearchFilter();
                        }
                    }

                    focusPolicy: Qt.StrongFocus
                    KeyNavigation.left: refreshButton
                    KeyNavigation.right: filterToggle
                    KeyNavigation.down: gamesGrid.count > 0 ? gamesGrid : null
                    KeyNavigation.up: mainTabBar ? mainTabBar.itemAt(1) : null
                    Keys.onReturnPressed: {
                        sortState = (sortState + 1) % 3;
                        Chiaki.settings.cloudSortState = sortState;
                        applySearchFilter();
                        event.accepted = true;
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
        
        // Region-group fallback banner (yellow).
        // Only a genuine "region has no native cloud" signal: suppressed when an auth error is
        // present, because nativeMode=false is then just a side-effect of the failed login (we
        // never determined the region) -- the red expired banner below is the real reason.
        Rectangle {
            id: fallbackBanner
            Layout.fillWidth: true
            Layout.preferredHeight: (!catalogNativeMode && authErrorMessage.length === 0 && !isLoading) ? 56 : 0
            // Gate on !isLoading: catalogNativeMode holds a stale persisted value mid-fetch, so the
            // banner must only reflect a COMPLETED fetch (otherwise it flashes while games load).
            visible: !catalogNativeMode && authErrorMessage.length === 0 && !isLoading
            color: Qt.rgba(255/255, 193/255, 7/255, 0.2)
            border.color: "#FFC107"
            border.width: 2
            clip: true

            Behavior on Layout.preferredHeight {
                NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
            }

            Label {
                anchors {
                    fill: parent
                    leftMargin: 20
                    rightMargin: 20
                    topMargin: 8
                    bottomMargin: 8
                }
                text: qsTr("PlayStation cloud isn't offered natively in your region — showing the %1 catalog. Some titles may not stream.").arg(fallbackRegion)
                wrapMode: Text.Wrap
                color: "#FFFFFF"
                font.pixelSize: 13
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }

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
                    cellWidth: 200
                    cellHeight: 280
                    focus: true
                    clip: true
                    flickableDirection: Flickable.VerticalFlick
                    boundsBehavior: Flickable.StopAtBounds
                    
                    KeyNavigation.up: filterToggle
                    
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
                        qrCodeDialog: root.qrCodeDialogRef
                        
                        // Bind isFavorite to favoriteProductIds array changes
                        Binding on isFavorite {
                            value: {
                                if (!modelData) return false;
                                let productId = modelData.productId || modelData.product_id || modelData.id;
                                // Force re-evaluation by referencing the array
                                let favs = root.favoriteProductIds;
                                return favs.indexOf(productId) !== -1;
                            }
                        }
                        
                        onToggleFavorite: (productId) => {
                            root.toggleFavorite(productId);
                        }
                        
                        Component.onCompleted: {
                            console.log("[CloudPlayView] CloudGameCard created, qrCodeDialog property:", qrCodeDialog);
                            console.log("[CloudPlayView] root.qrCodeDialogRef:", root ? root.qrCodeDialogRef : "root is null");
                        }
                        
                        onStreamGame: (streamingId, platform, serviceType) => {
                            console.log("Stream game:", streamingId, platform, serviceType);
                            
                            // Show StreamView immediately with loading spinner
                            // Find Main component by traversing parent chain
                            let mainComp = root;
                            while (mainComp && !mainComp.showStreamView) {
                                mainComp = mainComp.parent;
                            }
                            if (mainComp && mainComp.showStreamView) {
                                mainComp.showStreamView();
                            }
                            
                            // CloudGameCard now sends the correct identifier directly
                            // (entitlement ID for PSCloud, product ID for PSNOW)
                            Chiaki.cloudStreaming.startCompleteCloudSession(
                                serviceType,
                                streamingId,
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
                        
                        onCreateShortcut: (productId, entitlementId, platform, serviceType, gameName) => {
                            console.log("Create shortcut for cloud game:", gameName, "productId:", productId, "entitlementId:", entitlementId, platform, serviceType);
                            
                            // Determine the command and identifier to use
                            let command;
                            let gameIdentifier = entitlementId; // Use entitlement ID for launch command
                            
                            if (serviceType === "psnow") {
                                command = "cloudGameCatalog";
                                // For PSNOW, entitlementId is the same as productId
                                gameIdentifier = entitlementId;
                            } else if (serviceType === "pscloud") {
                                command = "cloudGameLibrary";
                                // For PSCloud, use entitlement ID for the launch command
                                gameIdentifier = entitlementId;
                            } else {
                                showErrorToast(qsTr("Error"), qsTr("Unknown service type: %1").arg(serviceType));
                                return;
                            }
                            
                            // Show the dialog - it will fetch game details itself using productId
                            // gameIdentifier (entitlementId) is used for the launch command
                            cloudShortcutDialog.showCloudDialog(gameName, gameIdentifier, serviceType, command, productId);
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
                            filterToggle.forceActiveFocus();
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
                        
                        // Square/X button - Create shortcut (same gate as the card's button/X handler:
                        // Steam installed and game not in the non-owned "Add Game" state)
                        if (event.key === Qt.Key_X || event.key === Qt.Key_Backslash || event.key === Qt.Key_No) {
                            if (currentItem && currentItem.createShortcut && currentItem.showCloudSteamShortcut) {
                                // Use getProductIdForApi() to get the correct product ID for API calls
                                let productId = currentItem.getProductIdForApi ? currentItem.getProductIdForApi() : currentItem.getProductId();
                                // Use getStreamingIdentifier() to get the entitlement ID for launch command
                                let entitlementId = currentItem.getStreamingIdentifier ? currentItem.getStreamingIdentifier() : currentItem.getProductId();
                                let platform = currentItem.getPlatform();
                                let serviceType = currentItem.getServiceType();
                                let gameName = currentItem.getGameName();
                                if (productId !== "") {
                                    currentItem.createShortcut(productId, entitlementId, platform, serviceType, gameName);
                                    event.accepted = true;
                                }
                            }
                            return;
                        }
                        
                        switch (event.key) {
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
                            // Ensure focus when model changes, but never steal it from the
                            // search field or an open modal (e.g. the filter dialog), otherwise
                            // a live re-filter yanks focus back to the grid mid-interaction.
                            Qt.callLater(() => {
                                if (count > 0 && !searchField.activeFocus && !tagFilterPopup.opened) {
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
                            // Only auto-focus if neither the search field nor the filter dialog
                            // is active; a live re-filter must not pull focus off an open modal.
                            Qt.callLater(() => {
                                if (count > 0 && !searchField.activeFocus && !tagFilterPopup.opened) {
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
        
    }
    
    // QR Code Dialog
    QRCodeDialog {
        id: qrCodeDialog
        
        Component.onCompleted: {
            root.qrCodeDialogRef = qrCodeDialog;
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
