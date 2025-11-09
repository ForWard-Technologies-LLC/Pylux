import QtQuick
import QtQuick.Effects

Rectangle {
    id: root
    color: "#000000"
    
    // Dark purple flowing gradient background - easier on the eyes
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: "#1a0a25" }
            GradientStop { position: 0.25; color: "#25154a" }
            GradientStop { position: 0.5; color: "#3d1b65" }
            GradientStop { position: 0.75; color: "#522c7d" }
            GradientStop { position: 1.0; color: "#250e3a" }
        }
    }
    
    // Flowing abstract shapes overlay
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(0.4, 0.15, 0.5, 0.3) }
            GradientStop { position: 0.3; color: Qt.rgba(0.6, 0.15, 0.7, 0.2) }
            GradientStop { position: 0.7; color: Qt.rgba(0.7, 0.25, 0.8, 0.15) }
            GradientStop { position: 1.0; color: Qt.rgba(0.5, 0.1, 0.5, 0.25) }
        }
        opacity: 0.6
    }
    
    // Diagonal flowing shapes
    Rectangle {
        anchors.fill: parent
        rotation: 15
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: Qt.rgba(0.85, 0.35, 0.8, 0.1) }
            GradientStop { position: 0.4; color: Qt.rgba(0.5, 0.3, 0.8, 0.12) }
            GradientStop { position: 0.6; color: Qt.rgba(0.7, 0.2, 0.7, 0.1) }
            GradientStop { position: 1.0; color: Qt.rgba(0.4, 0.1, 0.6, 0.2) }
        }
        opacity: 0.4
    }
    
    // Secondary flowing layer
    Rectangle {
        anchors.fill: parent
        rotation: -12
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: Qt.rgba(0.4, 0.25, 0.7, 0.08) }
            GradientStop { position: 0.3; color: Qt.rgba(0.75, 0.25, 0.75, 0.12) }
            GradientStop { position: 0.7; color: Qt.rgba(0.5, 0.3, 0.8, 0.06) }
            GradientStop { position: 1.0; color: Qt.rgba(0.6, 0.2, 0.7, 0.1) }
        }
        opacity: 0.3
    }
    
    // Soft radial highlights (like the flowing light effects in the reference) - more purple
    Rectangle {
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: -width * 0.3
        anchors.verticalCenterOffset: -height * 0.2
        width: parent.width * 0.8
        height: parent.height * 0.6
        radius: width * 0.5
        color: Qt.rgba(0.5, 0.5, 0.85, 0.06)
        
        layer.enabled: true
        layer.effect: MultiEffect {
            blurEnabled: true
            blurMax: 64
            blur: 0.8
        }
    }
    
    // Secondary highlight
    Rectangle {
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: width * 0.4
        anchors.verticalCenterOffset: height * 0.3
        width: parent.width * 0.6
        height: parent.height * 0.4
        radius: width * 0.5
        color: Qt.rgba(0.85, 0.3, 0.85, 0.06)
        
        layer.enabled: true
        layer.effect: MultiEffect {
            blurEnabled: true
            blurMax: 48
            blur: 0.9
        }
    }
}
