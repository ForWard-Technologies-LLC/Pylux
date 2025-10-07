import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

DialogView {
    id: walkthroughDialog
    
    property int currentStep: 0
    property int totalSteps: 4
    
    title: qsTr("Console Setup Guide")
    buttonText: currentStep < totalSteps - 1 ? qsTr("Next") : qsTr("Done")
    buttonEnabled: true
    
    onAccepted: nextStep()
    
    function nextStep() {
        if (currentStep < totalSteps - 1) {
            currentStep++
        } else {
            close()
        }
    }
    
    function previousStep() {
        if (currentStep > 0) {
            currentStep--
        }
    }
    
    function getStepTitle(step) {
        switch(step) {
            case 0: return qsTr("Enable Remote Play")
            case 1: return qsTr("Same WiFi Network")
            case 2: return qsTr("Add Manually")
            case 3: return qsTr("Register Console")
            default: return ""
        }
    }
    
    // Main content for DialogView
    mainItem: Item {
        anchors.fill: parent
        
        // Modern step progress indicator
        Rectangle {
            id: progressHeader
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 20
            height: 80
            radius: 12
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0, 212/255, 1, 0.15) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 212/255, 1, 0.05) }
            }
            border.color: Qt.rgba(0, 212/255, 1, 0.3)
            border.width: 1
            
            RowLayout {
                anchors.fill: parent
                anchors.margins: 20
                
                // Step counter
                Rectangle {
                    Layout.preferredWidth: 60
                    Layout.preferredHeight: 40
                    radius: 20
                    color: Qt.rgba(0, 212/255, 1, 1)
                    
                    Label {
                        anchors.centerIn: parent
                        text: (walkthroughDialog.currentStep + 1) + "/" + walkthroughDialog.totalSteps
                        font.pixelSize: 14
                        font.weight: Font.Bold
                        color: Qt.rgba(10/255, 15/255, 26/255, 1.0)
                    }
                }
                
                // Progress bar
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 6
                    Layout.alignment: Qt.AlignVCenter
                    radius: 3
                    color: Qt.rgba(1, 1, 1, 0.1)
                    
                    Rectangle {
                        width: parent.width * (walkthroughDialog.currentStep + 1) / walkthroughDialog.totalSteps
                        height: parent.height
                        radius: parent.radius
                        color: Qt.rgba(0, 212/255, 1, 1)
                        
                        Behavior on width {
                            NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
                        }
                    }
                }
                
                // Step title
                Label {
                    Layout.preferredWidth: 200
                    text: walkthroughDialog.getStepTitle(walkthroughDialog.currentStep)
                    font.pixelSize: 16
                    font.weight: Font.Medium
                    color: Qt.rgba(0, 212/255, 1, 1)
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                }
            }
        }
        
        // Main swipeable content area
        Item {
            id: contentArea
            anchors.top: progressHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: navigationFooter.top
            anchors.margins: 20
            clip: true
            
            // Swipe view for smooth transitions
            ListView {
                id: stepView
                anchors.fill: parent
                orientation: ListView.Horizontal
                snapMode: ListView.SnapOneItem
                highlightRangeMode: ListView.StrictlyEnforceRange
                highlightMoveDuration: 300
                currentIndex: walkthroughDialog.currentStep
                interactive: true
                boundsBehavior: Flickable.StopAtBounds
                
                onCurrentIndexChanged: {
                    if (currentIndex !== walkthroughDialog.currentStep) {
                        walkthroughDialog.currentStep = currentIndex
                    }
                }
                
                model: 4
                delegate: Item {
                    width: stepView.width
                    height: stepView.height
                    
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 10
                        radius: 16
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Qt.rgba(0, 212/255, 1, 0.08) }
                            GradientStop { position: 1.0; color: Qt.rgba(0, 212/255, 1, 0.03) }
                        }
                        border.color: Qt.rgba(0, 212/255, 1, 0.2)
                        border.width: 1
                        
                        // Content based on step index
                        Item {
                            anchors.fill: parent
                            anchors.margins: 30
                            
                            // Step 1 content
                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 30
                                visible: index === 0
                                
                                // Icon and title
                                ColumnLayout {
                                    Layout.alignment: Qt.AlignHCenter
                                    spacing: 15
                                    
                                    Rectangle {
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.preferredWidth: 80
                                        Layout.preferredHeight: 80
                                        radius: 40
                                        gradient: Gradient {
                                            GradientStop { position: 0.0; color: Qt.rgba(0, 212/255, 1, 1) }
                                            GradientStop { position: 1.0; color: Qt.rgba(0, 212/255, 1, 0.7) }
                                        }
                                        
                                        Label {
                                            anchors.centerIn: parent
                                            text: "🎮"
                                            font.pixelSize: 36
                                        }
                                    }
                                    
                                    Label {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: qsTr("Step 1: Enable Remote Play on Your Console")
                                        font.pixelSize: 24
                                        font.weight: Font.Bold
                                        color: Qt.rgba(0, 212/255, 1, 1)
                                        horizontalAlignment: Text.AlignHCenter
                                    }
                                }
                                
                                // Instructions card
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: instructionsColumn1.implicitHeight + 40
                                    radius: 12
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: Qt.rgba(1, 193/255, 7/255, 0.1) }
                                        GradientStop { position: 1.0; color: Qt.rgba(1, 193/255, 7/255, 0.05) }
                                    }
                                    border.color: Qt.rgba(1, 193/255, 7/255, 0.3)
                                    border.width: 1
                                    
                                    ColumnLayout {
                                        id: instructionsColumn1
                                        anchors.centerIn: parent
                                        width: parent.width - 40
                                        spacing: 20
                                        
                                        Label {
                                            Layout.alignment: Qt.AlignHCenter
                                            text: qsTr("Navigate to your console's Remote Play settings:")
                                            font.pixelSize: 18
                                            font.weight: Font.Medium
                                            color: Qt.rgba(1, 1, 1, 0.9)
                                        }
                                        
                                        ColumnLayout {
                                            Layout.alignment: Qt.AlignHCenter
                                            spacing: 12
                                            
                                            Rectangle {
                                                Layout.alignment: Qt.AlignHCenter
                                                Layout.preferredWidth: pathLabel1.implicitWidth + 20
                                                Layout.preferredHeight: 40
                                                radius: 8
                                                color: Qt.rgba(0, 0, 0, 0.3)
                                                border.color: Qt.rgba(1, 1, 1, 0.2)
                                                border.width: 1
                                                
                                                Label {
                                                    id: pathLabel1
                                                    anchors.centerIn: parent
                                                    text: qsTr("PS5: Settings → System → Remote Play")
                                                    font.pixelSize: 16
                                                    color: Qt.rgba(0, 212/255, 1, 1)
                                                    font.family: "monospace"
                                                }
                                            }
                                            
                                            Rectangle {
                                                Layout.alignment: Qt.AlignHCenter
                                                Layout.preferredWidth: pathLabel2.implicitWidth + 20
                                                Layout.preferredHeight: 40
                                                radius: 8
                                                color: Qt.rgba(0, 0, 0, 0.3)
                                                border.color: Qt.rgba(1, 1, 1, 0.2)
                                                border.width: 1
                                                
                                                Label {
                                                    id: pathLabel2
                                                    anchors.centerIn: parent
                                                    text: qsTr("PS4: Settings → Remote Play Connection Settings")
                                                    font.pixelSize: 16
                                                    color: Qt.rgba(0, 212/255, 1, 1)
                                                    font.family: "monospace"
                                                }
                                            }
                                        }
                                        
                                        Label {
                                            Layout.alignment: Qt.AlignHCenter
                                            Layout.fillWidth: true
                                            text: qsTr("✓ Enable Remote Play and make sure your console is connected to the internet")
                                            font.pixelSize: 14
                                            color: Qt.rgba(1, 1, 1, 0.8)
                                            horizontalAlignment: Text.AlignHCenter
                                            wrapMode: Text.WordWrap
                                        }
                                    }
                                }
                            }
                            
                            // Step 2 content
                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 30
                                visible: index === 1
                                
                                // Icon and title
                                ColumnLayout {
                                    Layout.alignment: Qt.AlignHCenter
                                    spacing: 15
                                    
                                    Rectangle {
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.preferredWidth: 80
                                        Layout.preferredHeight: 80
                                        radius: 40
                                        gradient: Gradient {
                                            GradientStop { position: 0.0; color: Qt.rgba(1, 152/255, 0, 1) }
                                            GradientStop { position: 1.0; color: Qt.rgba(1, 152/255, 0, 0.7) }
                                        }
                                        
                                        Label {
                                            anchors.centerIn: parent
                                            text: "📶"
                                            font.pixelSize: 36
                                        }
                                    }
                                    
                                    Label {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: qsTr("Step 2: Connect to the Same WiFi Network")
                                        font.pixelSize: 24
                                        font.weight: Font.Bold
                                        color: Qt.rgba(1, 152/255, 0, 1)
                                        horizontalAlignment: Text.AlignHCenter
                                    }
                                }
                                
                                // Warning card
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: instructionsColumn2.implicitHeight + 40
                                    radius: 12
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: Qt.rgba(1, 193/255, 7/255, 0.15) }
                                        GradientStop { position: 1.0; color: Qt.rgba(1, 193/255, 7/255, 0.05) }
                                    }
                                    border.color: Qt.rgba(1, 193/255, 7/255, 0.4)
                                    border.width: 2
                                    
                                    ColumnLayout {
                                        id: instructionsColumn2
                                        anchors.centerIn: parent
                                        width: parent.width - 40
                                        spacing: 20
                                        
                                        Label {
                                            Layout.alignment: Qt.AlignHCenter
                                            text: qsTr("⚠️ Important: Discovery & Registration Requirement")
                                            font.pixelSize: 20
                                            font.weight: Font.Bold
                                            color: Qt.rgba(1, 152/255, 0, 1)
                                        }
                                        
                                        Rectangle {
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: warningText.implicitHeight + 20
                                            radius: 8
                                            color: Qt.rgba(0, 0, 0, 0.2)
                                            border.color: Qt.rgba(1, 1, 1, 0.1)
                                            border.width: 1
                                            
                                            Label {
                                                id: warningText
                                                anchors.centerIn: parent
                                                width: parent.width - 20
                                                text: qsTr("To register your console with PSStream, both your device and console must be connected to the same WiFi network. This is required even if you plan to use remote play away from home later.")
                                                font.pixelSize: 16
                                                color: Qt.rgba(1, 1, 1, 0.9)
                                                horizontalAlignment: Text.AlignHCenter
                                                wrapMode: Text.WordWrap
                                            }
                                        }
                                        
                                        Label {
                                            Layout.alignment: Qt.AlignHCenter
                                            Layout.fillWidth: true
                                            text: qsTr("✓ Make sure both devices are on the same network, then PSStream should automatically discover your console.")
                                            font.pixelSize: 14
                                            color: Qt.rgba(1, 1, 1, 0.8)
                                            horizontalAlignment: Text.AlignHCenter
                                            wrapMode: Text.WordWrap
                                        }
                                    }
                                }
                            }
                            
                            // Step 3 content
                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 30
                                visible: index === 2
                                
                                // Icon and title
                                ColumnLayout {
                                    Layout.alignment: Qt.AlignHCenter
                                    spacing: 15
                                    
                                    Rectangle {
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.preferredWidth: 80
                                        Layout.preferredHeight: 80
                                        radius: 40
                                        gradient: Gradient {
                                            GradientStop { position: 0.0; color: Qt.rgba(76/255, 175/255, 80/255, 1) }
                                            GradientStop { position: 1.0; color: Qt.rgba(76/255, 175/255, 80/255, 0.7) }
                                        }
                                        
                                        Label {
                                            anchors.centerIn: parent
                                            text: "🔧"
                                            font.pixelSize: 36
                                        }
                                    }
                                    
                                    Label {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: qsTr("Step 3: Add Console Manually (If Needed)")
                                        font.pixelSize: 24
                                        font.weight: Font.Bold
                                        color: Qt.rgba(76/255, 175/255, 80/255, 1)
                                        horizontalAlignment: Text.AlignHCenter
                                    }
                                }
                                
                                // Instructions card
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: instructionsColumn3.implicitHeight + 40
                                    radius: 12
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: Qt.rgba(76/255, 175/255, 80/255, 0.1) }
                                        GradientStop { position: 1.0; color: Qt.rgba(76/255, 175/255, 80/255, 0.05) }
                                    }
                                    border.color: Qt.rgba(76/255, 175/255, 80/255, 0.3)
                                    border.width: 1
                                    
                                    ColumnLayout {
                                        id: instructionsColumn3
                                        anchors.centerIn: parent
                                        width: parent.width - 40
                                        spacing: 20
                                        
                                        Label {
                                            Layout.alignment: Qt.AlignHCenter
                                            text: qsTr("If your console doesn't appear automatically:")
                                            font.pixelSize: 18
                                            font.weight: Font.Medium
                                            color: Qt.rgba(1, 1, 1, 0.9)
                                        }
                                        
                                        Rectangle {
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: manualText.implicitHeight + 20
                                            radius: 8
                                            color: Qt.rgba(0, 0, 0, 0.2)
                                            border.color: Qt.rgba(1, 1, 1, 0.1)
                                            border.width: 1
                                            
                                            Label {
                                                id: manualText
                                                anchors.centerIn: parent
                                                width: parent.width - 20
                                                text: qsTr("You can add your console manually using its IP address. Find your console's IP in its network settings, then use the 'Add Console Manually' button from the main screen.")
                                                font.pixelSize: 16
                                                color: Qt.rgba(1, 1, 1, 0.9)
                                                horizontalAlignment: Text.AlignHCenter
                                                wrapMode: Text.WordWrap
                                            }
                                        }
                                        
                                        Label {
                                            Layout.alignment: Qt.AlignHCenter
                                            Layout.fillWidth: true
                                            text: qsTr("💡 Note: You should only need to do this if automatic discovery isn't working on your network.")
                                            font.pixelSize: 14
                                            color: Qt.rgba(1, 1, 1, 0.7)
                                            horizontalAlignment: Text.AlignHCenter
                                            wrapMode: Text.WordWrap
                                            font.italic: true
                                        }
                                    }
                                }
                            }
                            
                            // Step 4 content
                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 25
                                visible: index === 3
                                
                                // Icon and title
                                ColumnLayout {
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.topMargin: 10
                                    spacing: 15
                                    
                                    Rectangle {
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.preferredWidth: 80
                                        Layout.preferredHeight: 80
                                        radius: 40
                                        gradient: Gradient {
                                            GradientStop { position: 0.0; color: Qt.rgba(156/255, 39/255, 176/255, 1) }
                                            GradientStop { position: 1.0; color: Qt.rgba(156/255, 39/255, 176/255, 0.7) }
                                        }
                                        
                                        Label {
                                            anchors.centerIn: parent
                                            text: "🌐"
                                            font.pixelSize: 36
                                        }
                                    }
                                    
                                    Label {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: qsTr("Step 4: Register Your Console")
                                        font.pixelSize: 26
                                        font.weight: Font.Bold
                                        color: Qt.rgba(156/255, 39/255, 176/255, 1)
                                        horizontalAlignment: Text.AlignHCenter
                                    }
                                    
                                    Label {
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.topMargin: -5
                                        text: qsTr("Once your console appears, click on it to register")
                                        font.pixelSize: 16
                                        color: Qt.rgba(1, 1, 1, 0.8)
                                        horizontalAlignment: Text.AlignHCenter
                                    }
                                }
                                
                                // Recommended: PSN Login (Prominent)
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: psnRecommendedContent.implicitHeight + 50
                                    Layout.topMargin: 10
                                    radius: 12
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: Qt.rgba(76/255, 175/255, 80/255, 0.25) }
                                        GradientStop { position: 1.0; color: Qt.rgba(76/255, 175/255, 80/255, 0.15) }
                                    }
                                    border.color: Qt.rgba(76/255, 175/255, 80/255, 0.5)
                                    border.width: 2
                                    
                                    ColumnLayout {
                                        id: psnRecommendedContent
                                        anchors.centerIn: parent
                                        width: parent.width - 50
                                        spacing: 15
                                        
                                        Label {
                                            Layout.alignment: Qt.AlignHCenter
                                            text: qsTr("✅ Recommended: PSN Login (Automatic)")
                                            font.pixelSize: 18
                                            font.weight: Font.Bold
                                            color: Qt.rgba(76/255, 175/255, 80/255, 1)
                                            horizontalAlignment: Text.AlignHCenter
                                        }
                                        
                                        Label {
                                            Layout.fillWidth: true
                                            text: qsTr("Login to PSN from the main menu, then click your console for automatic registration.")
                                            font.pixelSize: 16
                                            color: Qt.rgba(1, 1, 1, 0.95)
                                            horizontalAlignment: Text.AlignHCenter
                                            wrapMode: Text.WordWrap
                                        }
                                        
                                        Label {
                                            Layout.fillWidth: true
                                            text: qsTr("No PIN or Account ID needed!")
                                            font.pixelSize: 15
                                            font.weight: Font.Bold
                                            color: Qt.rgba(76/255, 175/255, 80/255, 1)
                                            horizontalAlignment: Text.AlignHCenter
                                            wrapMode: Text.WordWrap
                                        }
                                    }
                                }
                                
                                // Alternative: Manual Registration (Subtle)
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: manualRegContent.implicitHeight + 40
                                    radius: 10
                                    color: Qt.rgba(0, 0, 0, 0.15)
                                    border.color: Qt.rgba(1, 1, 1, 0.15)
                                    border.width: 1
                                    
                                    ColumnLayout {
                                        id: manualRegContent
                                        anchors.centerIn: parent
                                        width: parent.width - 40
                                        spacing: 12
                                        
                                        Label {
                                            Layout.alignment: Qt.AlignHCenter
                                            text: qsTr("Alternative: Manual Registration")
                                            font.pixelSize: 16
                                            font.weight: Font.Medium
                                            color: Qt.rgba(1, 1, 1, 0.75)
                                            horizontalAlignment: Text.AlignHCenter
                                        }
                                        
                                        Label {
                                            Layout.fillWidth: true
                                            text: qsTr("Click your console, enter the PIN from your console screen, and use 'Public Lookup' to find your PSN Account ID.")
                                            font.pixelSize: 15
                                            color: Qt.rgba(1, 1, 1, 0.7)
                                            horizontalAlignment: Text.AlignHCenter
                                            wrapMode: Text.WordWrap
                                        }
                                    }
                                }
                                
                                // Bottom tip
                                Label {
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.fillWidth: true
                                    Layout.topMargin: 5
                                    text: qsTr("💡 After registration, PSN login enables remote play from anywhere without port forwarding.")
                                    font.pixelSize: 13
                                    color: Qt.rgba(1, 1, 1, 0.65)
                                    horizontalAlignment: Text.AlignHCenter
                                    wrapMode: Text.WordWrap
                                    font.italic: true
                                }
                            }
                        }
                    }
                }
            }
            
            // Sync ListView with currentStep
            Connections {
                target: walkthroughDialog
                function onCurrentStepChanged() {
                    if (stepView.currentIndex !== walkthroughDialog.currentStep) {
                        stepView.currentIndex = walkthroughDialog.currentStep
                    }
                }
            }
        }
        
        // Navigation footer with arrow buttons and keyboard support
        Rectangle {
            id: navigationFooter
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 20
            height: 80
            radius: 12
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0, 212/255, 1, 0.1) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 212/255, 1, 0.05) }
            }
            border.color: Qt.rgba(0, 212/255, 1, 0.2)
            border.width: 1
            
            RowLayout {
                anchors.fill: parent
                anchors.margins: 20
                
                // Exit button (left)
                Button {
                    id: exitButton
                    Layout.preferredWidth: 100
                    Layout.preferredHeight: 40
                    text: "✕ " + qsTr("Exit")
                    
                    background: Rectangle {
                        radius: 8
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Qt.rgba(1, 0.3, 0.3, 0.2) }
                            GradientStop { position: 1.0; color: Qt.rgba(1, 0.3, 0.3, 0.1) }
                        }
                        border.color: Qt.rgba(1, 0.3, 0.3, 0.4)
                        border.width: 1
                    }
                    
                    contentItem: Label {
                        text: parent.text
                        font.pixelSize: 14
                        font.weight: Font.Medium
                        color: Qt.rgba(1, 0.5, 0.5, 1)
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    
                    onClicked: walkthroughDialog.close()
                }
                
                // Previous button
                Button {
                    id: prevButton
                    Layout.preferredWidth: 120
                    Layout.preferredHeight: 40
                    text: "← " + qsTr("Previous")
                    enabled: walkthroughDialog.currentStep > 0
                    opacity: enabled ? 1.0 : 0.3
                    
                    background: Rectangle {
                        radius: 8
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: parent.enabled ? Qt.rgba(0, 212/255, 1, 0.2) : Qt.rgba(1, 1, 1, 0.1) }
                            GradientStop { position: 1.0; color: parent.enabled ? Qt.rgba(0, 212/255, 1, 0.1) : Qt.rgba(1, 1, 1, 0.05) }
                        }
                        border.color: parent.enabled ? Qt.rgba(0, 212/255, 1, 0.4) : Qt.rgba(1, 1, 1, 0.2)
                        border.width: 1
                    }
                    
                    contentItem: Label {
                        text: parent.text
                        font.pixelSize: 14
                        font.weight: Font.Medium
                        color: parent.enabled ? Qt.rgba(0, 212/255, 1, 1) : Qt.rgba(1, 1, 1, 0.5)
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    
                    onClicked: walkthroughDialog.previousStep()
                    
                    Behavior on opacity {
                        NumberAnimation { duration: 200 }
                    }
                }
                
                // Center spacer with navigation hint
                Item {
                    Layout.fillWidth: true
                    
                    Label {
                        anchors.centerIn: parent
                        text: qsTr("Use ← → arrow keys or swipe to navigate")
                        font.pixelSize: 12
                        color: Qt.rgba(1, 1, 1, 0.6)
                        font.italic: true
                    }
                }
                
                // Next/Done button
                Button {
                    id: nextButton
                    Layout.preferredWidth: 120
                    Layout.preferredHeight: 40
                    text: (walkthroughDialog.currentStep < walkthroughDialog.totalSteps - 1 ? qsTr("Next") : qsTr("Done")) + " →"
                    
                    background: Rectangle {
                        radius: 8
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: walkthroughDialog.currentStep < walkthroughDialog.totalSteps - 1 ? Qt.rgba(0, 212/255, 1, 0.3) : Qt.rgba(76/255, 175/255, 80/255, 0.3) }
                            GradientStop { position: 1.0; color: walkthroughDialog.currentStep < walkthroughDialog.totalSteps - 1 ? Qt.rgba(0, 212/255, 1, 0.2) : Qt.rgba(76/255, 175/255, 80/255, 0.2) }
                        }
                        border.color: walkthroughDialog.currentStep < walkthroughDialog.totalSteps - 1 ? Qt.rgba(0, 212/255, 1, 0.5) : Qt.rgba(76/255, 175/255, 80/255, 0.5)
                        border.width: 1
                    }
                    
                    contentItem: Label {
                        text: parent.text
                        font.pixelSize: 14
                        font.weight: Font.Bold
                        color: walkthroughDialog.currentStep < walkthroughDialog.totalSteps - 1 ? Qt.rgba(0, 212/255, 1, 1) : Qt.rgba(76/255, 175/255, 80/255, 1)
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    
                    onClicked: walkthroughDialog.nextStep()
                }
            }
        }
        
        // Keyboard and gamepad navigation
        focus: true
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Left) {
                if (walkthroughDialog.currentStep > 0) {
                    walkthroughDialog.previousStep()
                    event.accepted = true
                }
            } else if (event.key === Qt.Key_Right) {
                if (walkthroughDialog.currentStep < walkthroughDialog.totalSteps - 1) {
                    walkthroughDialog.nextStep()
                    event.accepted = true
                } else {
                    walkthroughDialog.close()
                    event.accepted = true
                }
            } else if (event.key === Qt.Key_Escape) {
                walkthroughDialog.close()
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                walkthroughDialog.nextStep()
                event.accepted = true
            }
        }
    }
}