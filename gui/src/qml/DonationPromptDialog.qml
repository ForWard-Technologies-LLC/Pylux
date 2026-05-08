import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

import "controls" as C

DialogView {
    id: dialog
    title: qsTr("Support Pylux")
    buttonVisible: false

    property int showCount: DonationManager.promptShowCount
    property string currentPhrase: ""
    property real phraseRevealFraction: 0.0
    property real contentOpacity: 0.0
    property real qrScale: 0.0
    property bool showBullets: showCount <= 3
    property var flatPhrases: []
    property int borderSweepIndex: -1
    property real borderSweepProgress: 0.0
    property real borderSweepOpacity: 1.0
    property real framePulseProgress: 0.0
    property real framePulseOpacity: 1.0

    StackView.onActivated: {
        Chiaki.window.grabInput();
        flatPhrases = DonationManager.donationPhrases();
        if (!showBullets && flatPhrases.length > 0) {
            var phraseCallId = showCount - 3;
            var idx = ((phraseCallId - 1) % flatPhrases.length + flatPhrases.length) % flatPhrases.length;
            currentPhrase = flatPhrases[idx];
            phraseRevealFraction = 0.0;
            phraseRevealAnim.duration = Math.min(720, Math.max(320, 320 + currentPhrase.length * 16));
            phraseRevealAnim.start();
        }
        contentFadeIn.start();
        qrPopIn.start();
        framePulseAnim.start();
        framePulseFadeTimer.start();
    }

    StackView.onDeactivating: {
        Chiaki.window.releaseInput();
    }

    function close() {
        DonationManager.dismiss();
        root.closeDialog();
    }

    function startBorderSweepCycle() {
        if (!DonationManager.isAppStore || DonationManager.iapTiers.length === 0) return;
        dialog.borderSweepIndex = (dialog.borderSweepIndex + 1) % DonationManager.iapTiers.length;
        dialog.borderSweepOpacity = 0.0;
        borderGlowSequence.start();
    }

    Item {
        anchors.fill: parent

        NumberAnimation {
            id: phraseRevealAnim
            target: dialog
            property: "phraseRevealFraction"
            from: 0.0; to: 1.0
            duration: 500
            easing.type: Easing.Linear
        }

        NumberAnimation {
            id: contentFadeIn
            target: dialog
            property: "contentOpacity"
            from: 0.0; to: 1.0
            duration: 500
            easing.type: Easing.OutCubic
        }

        NumberAnimation {
            id: qrPopIn
            target: dialog
            property: "qrScale"
            from: 0.85; to: 1.0
            duration: 600
            easing.type: Easing.OutBack
        }

        NumberAnimation {
            id: framePulseAnim
            target: dialog
            property: "framePulseProgress"
            from: 0.0; to: 1.0
            duration: 720
            easing.type: Easing.Linear
        }

        Timer {
            id: framePulseFadeTimer
            interval: 720
            onTriggered: framePulseFade.start()
        }

        NumberAnimation {
            id: framePulseFade
            target: dialog
            property: "framePulseOpacity"
            from: 1.0; to: 0.0
            duration: 480
            easing.type: Easing.Linear
        }

        SequentialAnimation {
            id: borderGlowSequence

            NumberAnimation {
                target: dialog; property: "borderSweepOpacity"
                from: 0.0; to: 1.0; duration: 500
                easing.type: Easing.OutCubic
            }
            PauseAnimation { duration: 800 }
            NumberAnimation {
                target: dialog; property: "borderSweepOpacity"
                from: 1.0; to: 0.0; duration: 500
                easing.type: Easing.InCubic
            }
            PauseAnimation { duration: 400 }

            onFinished: dialog.startBorderSweepCycle()
        }

        Timer {
            id: borderSweepStartTimer
            interval: 500
            onTriggered: dialog.startBorderSweepCycle()
        }

        // Gradient header bar
        Rectangle {
            id: headerBar
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 72
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Qt.rgba(0, 0.62, 0.89, 0.35) }
                GradientStop { position: 0.5; color: Qt.rgba(0.10, 0.14, 0.20, 0.9) }
                GradientStop { position: 1.0; color: Qt.rgba(0.05, 0.07, 0.09, 1.0) }
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 28
                anchors.rightMargin: 28
                spacing: 14

                Image {
                    Layout.preferredWidth: 44
                    Layout.preferredHeight: 44
                    source: "qrc:icons/logo_square_1024.png"
                    fillMode: Image.PreserveAspectFit
                    smooth: true; mipmap: true
                    sourceSize.width: 88; sourceSize.height: 88
                }

                ColumnLayout {
                    spacing: 2
                    Label {
                        text: qsTr("Keep Pylux alive")
                        font.pixelSize: 20
                        font.weight: Font.Bold
                        color: "#00d4ff"
                        font.letterSpacing: 0.5
                    }
                    Label {
                        text: qsTr("Open source \u2022 Community-maintained \u2022 Free forever")
                        font.pixelSize: 13
                        color: "#B8C5D6"
                        font.letterSpacing: 0.3
                    }
                }

                Item { Layout.fillWidth: true }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                height: 1
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "#00d4ff" }
                    GradientStop { position: 0.5; color: Qt.rgba(0, 0.83, 1.0, 0.3) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
            }
        }

        // Main content
        RowLayout {
            anchors.top: headerBar.bottom
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 0
            opacity: contentOpacity

            // Left side: story
            Item {
                Layout.fillHeight: true
                Layout.preferredWidth: parent.width * 0.48

                Flickable {
                    anchors.fill: parent
                    anchors.margins: 28
                    contentHeight: leftColumn.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: leftColumn
                        width: parent.width
                        spacing: 0

                        // Title (always visible, matching iOS)
                        Label {
                            text: qsTr("Enjoying Pylux?")
                            font.pixelSize: 24
                            font.weight: Font.Bold
                            color: "#ffffff"
                        }

                        // Description (always visible, matching iOS text)
                        Label {
                            Layout.fillWidth: true
                            Layout.topMargin: 12
                            text: qsTr("It\u2019s open source and maintained by the community. Please consider supporting the project. Donations go to the developers who maintain it.")
                            font.pixelSize: 16
                            color: "#B8C5D6"
                            wrapMode: Text.Wrap
                            lineHeight: 1.5
                        }

                        Item { Layout.preferredHeight: 18 }

                        // Bullet points (shows 1-3, matching iOS bulletList)
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            visible: showBullets

                            Repeater {
                                model: DonationManager.isAppStore
                                    ? [
                                        qsTr("Your donation goes to the people who build and maintain Pylux."),
                                        qsTr("Single payment in the App Store. No subscription."),
                                        qsTr("Optional. You get the full app either way.")
                                      ]
                                    : [
                                        qsTr("Your donation goes to the people who build and maintain Pylux."),
                                        qsTr("Single payment via Stripe. No subscription."),
                                        qsTr("Optional. You get the full app either way.")
                                      ]

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.bottomMargin: 10
                                    spacing: 12

                                    Rectangle {
                                        Layout.preferredWidth: 6
                                        Layout.preferredHeight: 6
                                        Layout.alignment: Qt.AlignTop
                                        Layout.topMargin: 8
                                        radius: 3
                                        color: "#00d4ff"
                                    }

                                    Label {
                                        Layout.fillWidth: true
                                        text: modelData
                                        font.pixelSize: 16
                                        color: "#B8C5D6"
                                        wrapMode: Text.Wrap
                                        lineHeight: 1.4
                                    }
                                }
                            }
                        }

                        // Rotating phrase (shows 4+, matching iOS phraseView)
                        Label {
                            Layout.fillWidth: true
                            visible: !showBullets && currentPhrase.length > 0
                            text: currentPhrase.substring(0, Math.floor(currentPhrase.length * phraseRevealFraction))
                            font.pixelSize: 16
                            font.weight: Font.Bold
                            color: "#B8C5D6"
                            opacity: 0.2 + 0.8 * phraseRevealFraction
                            wrapMode: Text.Wrap
                            lineHeight: 1.5
                        }

                        Item { Layout.preferredHeight: 24 }

                        // Trust badge
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: trustRow.height + 20
                            radius: 10
                            color: Qt.rgba(0, 0.83, 1.0, 0.06)
                            border.color: Qt.rgba(0, 0.83, 1.0, 0.12)
                            border.width: 1

                            RowLayout {
                                id: trustRow
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: 14
                                anchors.rightMargin: 14
                                spacing: 10

                                Label {
                                    text: "\uD83D\uDD12"
                                    font.pixelSize: 18
                                }

                                Label {
                                    Layout.fillWidth: true
                                    text: DonationManager.isAppStore
                                          ? qsTr("One payment in the App Store. No subscription.")
                                          : qsTr("Secure one-time donation via Stripe. Your payment info never touches Pylux.")
                                    font.pixelSize: 13
                                    color: Qt.rgba(1, 1, 1, 0.5)
                                    wrapMode: Text.Wrap
                                    lineHeight: 1.3
                                }
                            }
                        }

                        Item { Layout.preferredHeight: 10 }
                    }
                }
            }

            // Vertical divider
            Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                Layout.topMargin: 16
                Layout.bottomMargin: 16
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 0.3; color: Qt.rgba(0, 0.83, 1.0, 0.2) }
                    GradientStop { position: 0.7; color: Qt.rgba(0, 0.83, 1.0, 0.2) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
            }

            // Right side: IAP tiers (App Store) or QR + actions (standalone)
            Item {
                Layout.fillHeight: true
                Layout.fillWidth: true

                ColumnLayout {
                    anchors.centerIn: parent
                    width: Math.min(parent.width - 40, 400)
                    spacing: 0

                    // === App Store: IAP tier cards ===
                    Loader {
                        Layout.fillWidth: true
                        active: DonationManager.isAppStore
                        visible: active
                        sourceComponent: Component {
                            ColumnLayout {
                                spacing: 0

                                Label {
                                    Layout.fillWidth: true
                                    text: qsTr("Choose an amount")
                                    font.pixelSize: 20
                                    font.weight: Font.Bold
                                    color: "#ffffff"
                                }

                                Label {
                                    Layout.fillWidth: true
                                    Layout.topMargin: 6
                                    text: qsTr("Pick a tier below. You only pay once.")
                                    font.pixelSize: 14
                                    color: "#B8C5D6"
                                    lineHeight: 1.3
                                }

                                Item { Layout.preferredHeight: 18 }

                                Repeater {
                                    id: tierRepeater
                                    model: DonationManager.iapTiers

                                    Item {
                                        id: tierDelegate
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 62
                                        Layout.bottomMargin: 10
                                        opacity: 0
                                        transform: Translate { id: tierSlide; y: 10 }

                                        Component.onCompleted: {
                                            tierRevealTimer.interval = Math.max(1, index * 90);
                                            tierRevealTimer.start();
                                        }

                                        Timer {
                                            id: tierRevealTimer
                                            repeat: false
                                            onTriggered: tierRevealAnim.start()
                                        }

                                        ParallelAnimation {
                                            id: tierRevealAnim
                                            NumberAnimation { target: tierDelegate; property: "opacity"; from: 0; to: 1; duration: 420; easing.type: Easing.OutCubic }
                                            NumberAnimation { target: tierSlide; property: "y"; from: 10; to: 0; duration: 420; easing.type: Easing.OutCubic }
                                            onFinished: {
                                                if (index === DonationManager.iapTiers.length - 1)
                                                    borderSweepStartTimer.start();
                                            }
                                        }

                                        Rectangle {
                                            id: tierCardBg
                                            anchors.fill: parent
                                            radius: 14
                                            color: tierMouse.containsMouse ? Qt.rgba(0.14, 0.19, 0.28, 1.0) : Qt.rgba(0.10, 0.14, 0.20, 1.0)
                                            border.color: dialog.borderSweepIndex === index
                                                ? Qt.rgba(0, 0.62, 0.89, dialog.borderSweepOpacity)
                                                : Qt.rgba(0, 0.62, 0.89, 0.25)
                                            border.width: dialog.borderSweepIndex === index ? 2.5 : 1
                                            opacity: DonationManager.purchasingProductId !== "" && DonationManager.purchasingProductId !== modelData.id ? 0.4 : 1.0

                                            Behavior on color { ColorAnimation { duration: 150 } }
                                            Behavior on opacity { NumberAnimation { duration: 200 } }
                                        }

                                        Rectangle {
                                            anchors.fill: parent
                                            anchors.margins: -2
                                            radius: 16
                                            color: "transparent"
                                            border.color: Qt.rgba(0, 0.62, 0.89, 0.4 * dialog.borderSweepOpacity)
                                            border.width: 4
                                            visible: dialog.borderSweepIndex === index
                                        }

                                        ColumnLayout {
                                            anchors.left: parent.left
                                            anchors.leftMargin: 18
                                            anchors.right: tierPriceRow.left
                                            anchors.rightMargin: 8
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 3

                                            Label {
                                                text: modelData.displayName
                                                font.pixelSize: 16
                                                font.weight: Font.Bold
                                                color: "#ffffff"
                                                elide: Text.ElideRight
                                                Layout.fillWidth: true
                                            }
                                            Label {
                                                text: modelData.blurb
                                                font.pixelSize: 13
                                                color: "#B8C5D6"
                                                elide: Text.ElideRight
                                                Layout.fillWidth: true
                                            }
                                        }

                                        BusyIndicator {
                                            anchors.right: parent.right
                                            anchors.rightMargin: 14
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 28; height: 28
                                            running: DonationManager.purchasingProductId === modelData.id
                                            visible: running
                                            Material.accent: "#00d4ff"
                                        }

                                        Row {
                                            id: tierPriceRow
                                            visible: DonationManager.purchasingProductId !== modelData.id
                                            anchors.right: parent.right
                                            anchors.rightMargin: 14
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 6

                                            Label {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: modelData.price
                                                font.pixelSize: 17
                                                font.weight: Font.Bold
                                                color: "#00d4ff"
                                            }

                                            Label {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: "\u203A"
                                                font.pixelSize: 20
                                                color: Qt.rgba(0, 0.83, 1.0, 0.6)
                                            }
                                        }

                                        MouseArea {
                                            id: tierMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (DonationManager.purchasingProductId === "")
                                                    DonationManager.purchaseProduct(modelData.id);
                                            }
                                        }
                                    }
                                }

                                BusyIndicator {
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.topMargin: 24
                                    running: DonationManager.iapTiers.length === 0 && !DonationManager.iapLoadFailed
                                    visible: running
                                    Material.accent: "#00d4ff"
                                }

                                Label {
                                    Layout.fillWidth: true
                                    Layout.topMargin: 16
                                    visible: DonationManager.iapLoadFailed
                                    text: qsTr("Could not load App Store products. Check your connection and try again.")
                                    font.pixelSize: 14
                                    color: Qt.rgba(1, 1, 1, 0.5)
                                    wrapMode: Text.Wrap
                                    horizontalAlignment: Text.AlignHCenter
                                }

                                Item { Layout.preferredHeight: 18 }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    Label {
                                        id: restoreBtn
                                        text: qsTr("Restore purchases")
                                        font.pixelSize: 14
                                        color: restoreMouse.containsMouse ? Qt.rgba(0.42, 0.71, 1.0, 1.0) : Qt.rgba(0.42, 0.71, 1.0, 0.8)
                                        font.underline: restoreMouse.containsMouse

                                        Behavior on color { ColorAnimation { duration: 150 } }

                                        MouseArea {
                                            id: restoreMouse
                                            anchors.fill: parent
                                            anchors.margins: -6
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: DonationManager.restorePurchases()
                                        }
                                    }

                                    Item { Layout.fillWidth: true }

                                    Label {
                                        id: maybeLaterButton
                                        text: qsTr("Maybe later")
                                        font.pixelSize: 14
                                        color: maybeLaterMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.7) : Qt.rgba(1, 1, 1, 0.4)
                                        font.underline: maybeLaterMouse.containsMouse

                                        Behavior on color { ColorAnimation { duration: 150 } }

                                        activeFocusOnTab: true
                                        Keys.onReturnPressed: dialog.close()
                                        Keys.onEnterPressed: dialog.close()

                                        MouseArea {
                                            id: maybeLaterMouse
                                            anchors.fill: parent
                                            anchors.margins: -6
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: dialog.close()
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // === Standalone: QR code + browser button ===
                    Loader {
                        Layout.fillWidth: true
                        active: !DonationManager.isAppStore
                        visible: active
                        sourceComponent: Component {
                            ColumnLayout {
                                spacing: 0

                                Label {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: qsTr("Scan to donate")
                                    font.pixelSize: 16
                                    font.weight: Font.Medium
                                    color: Qt.rgba(1, 1, 1, 0.7)
                                    font.letterSpacing: 0.5
                                }

                                Item { Layout.preferredHeight: 16 }

                                Item {
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.preferredWidth: 210
                                    Layout.preferredHeight: 210
                                    visible: DonationManager.paymentUrl !== ""
                                    scale: qrScale

                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: 230; height: 230
                                        radius: 16
                                        color: "transparent"
                                        border.color: Qt.rgba(0, 0.83, 1.0, 0.15)
                                        border.width: 2
                                    }

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 12
                                        color: "#ffffff"

                                        Image {
                                            id: qrCodeImage
                                            anchors.centerIn: parent
                                            width: 190; height: 190
                                            source: DonationManager.paymentUrl
                                                    ? "https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=" + encodeURIComponent(DonationManager.paymentUrl)
                                                    : ""
                                            fillMode: Image.PreserveAspectFit

                                            BusyIndicator {
                                                anchors.centerIn: parent
                                                running: qrCodeImage.status === Image.Loading
                                                visible: running
                                                Material.accent: "#00d4ff"
                                            }
                                        }
                                    }
                                }

                                Item { Layout.preferredHeight: 12 }

                                Label {
                                    Layout.alignment: Qt.AlignHCenter
                                    visible: DonationManager.paymentUrl !== ""
                                    text: qsTr("Point your phone camera here")
                                    font.pixelSize: 12
                                    color: Qt.rgba(1, 1, 1, 0.4)
                                }

                                Item { Layout.preferredHeight: 20 }

                                Rectangle {
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.preferredWidth: 220
                                    Layout.preferredHeight: 44
                                    radius: 22
                                    visible: DonationManager.paymentUrl !== ""
                                    color: browserBtnMouse.containsMouse ? Qt.rgba(0, 0.83, 1.0, 0.25) : Qt.rgba(0, 0.83, 1.0, 0.15)
                                    border.color: "#00d4ff"
                                    border.width: 1

                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    Label {
                                        anchors.centerIn: parent
                                        text: qsTr("Open in Browser")
                                        font.pixelSize: 15
                                        font.weight: Font.Medium
                                        color: "#00d4ff"
                                        font.letterSpacing: 0.3
                                    }

                                    MouseArea {
                                        id: browserBtnMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: DonationManager.openInBrowser()
                                    }
                                }

                                Item { Layout.preferredHeight: 12 }

                                Label {
                                    id: maybeLaterButtonStandalone
                                    Layout.alignment: Qt.AlignHCenter
                                    text: qsTr("Maybe later")
                                    font.pixelSize: 14
                                    color: maybeLaterMouseStandalone.containsMouse ? Qt.rgba(1, 1, 1, 0.7) : Qt.rgba(1, 1, 1, 0.4)
                                    font.underline: maybeLaterMouseStandalone.containsMouse

                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    activeFocusOnTab: true
                                    Keys.onReturnPressed: dialog.close()
                                    Keys.onEnterPressed: dialog.close()

                                    MouseArea {
                                        id: maybeLaterMouseStandalone
                                        anchors.fill: parent
                                        anchors.margins: -8
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: dialog.close()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Frame pulse overlay (blue border sweeps across entire view on load)
        Item {
            anchors.fill: parent
            visible: framePulseOpacity > 0
            clip: true
            z: 10

            Rectangle {
                width: parent.width * framePulseProgress
                height: parent.height
                color: "transparent"
                clip: true

                Rectangle {
                    width: parent.parent.width
                    height: parent.parent.height
                    color: "transparent"
                    border.color: "#009FE3"
                    border.width: 3
                }
            }
            opacity: framePulseOpacity
        }
    }
}
