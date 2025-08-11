import QtQuick
import QtQuick.Effects

// Reusable sparkle background component inspired by blue Christmas sparkles
Rectangle {
    id: sparkleBackground
    anchors.fill: parent
    
    // Deep blue gradient background
    gradient: Gradient {
        orientation: Gradient.Vertical
        GradientStop { position: 0.0; color: "#0a0f2a" }  // Deep navy
        GradientStop { position: 0.3; color: "#0d1545" }  // Medium blue
        GradientStop { position: 0.7; color: "#1a2550" }  // Lighter blue
        GradientStop { position: 1.0; color: "#0a0f2a" }  // Deep navy
    }
    
    // Large sparkles/stars
    Repeater {
        model: 15
        
        Item {
            property real sparkleSize: Math.random() * 8 + 4
            property real baseOpacity: Math.random() * 0.8 + 0.4
            property real animationSpeed: Math.random() * 3000 + 2000
            property real twinkleSpeed: Math.random() * 2000 + 1000
            
            x: Math.random() * parent.width
            y: Math.random() * parent.height
            width: sparkleSize * 2
            height: sparkleSize * 2
            
            // Cross-shaped sparkle
            Item {
                anchors.centerIn: parent
                
                // Horizontal beam
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.parent.sparkleSize * 2
                    height: 2
                    color: "#00d4ff"
                    opacity: parent.parent.baseOpacity
                    
                    // Glow effect
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        blurEnabled: true
                        blurMax: 12
                        blur: 0.8
                    }
                }
                
                // Vertical beam
                Rectangle {
                    anchors.centerIn: parent
                    width: 2
                    height: parent.parent.sparkleSize * 2
                    color: "#00d4ff"
                    opacity: parent.parent.baseOpacity
                    
                    // Glow effect
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        blurEnabled: true
                        blurMax: 12
                        blur: 0.8
                    }
                }
                
                // Center bright point
                Rectangle {
                    anchors.centerIn: parent
                    width: 4
                    height: 4
                    radius: 2
                    color: "#ffffff"
                    opacity: parent.parent.baseOpacity * 1.5
                    
                    // Bright glow
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        blurEnabled: true
                        blurMax: 8
                        blur: 1.0
                    }
                }
            }
            
            // Twinkling animation
            SequentialAnimation on baseOpacity {
                running: true
                loops: Animation.Infinite
                NumberAnimation {
                    to: parent.baseOpacity * 0.2
                    duration: parent.twinkleSpeed
                    easing.type: Easing.InOutQuad
                }
                NumberAnimation {
                    to: parent.baseOpacity * 1.5
                    duration: parent.twinkleSpeed
                    easing.type: Easing.InOutQuad
                }
            }
            
            // Gentle floating movement
            SequentialAnimation on y {
                running: true
                loops: Animation.Infinite
                NumberAnimation {
                    to: parent.y + (Math.random() * 30 - 15)
                    duration: parent.animationSpeed
                    easing.type: Easing.InOutSine
                }
                NumberAnimation {
                    to: parent.y
                    duration: parent.animationSpeed
                    easing.type: Easing.InOutSine
                }
            }
            
            // Scale animation for breathing effect
            SequentialAnimation on scale {
                running: true
                loops: Animation.Infinite
                NumberAnimation {
                    to: 0.7
                    duration: parent.twinkleSpeed * 1.5
                    easing.type: Easing.InOutQuad
                }
                NumberAnimation {
                    to: 1.3
                    duration: parent.twinkleSpeed * 1.5
                    easing.type: Easing.InOutQuad
                }
            }
        }
    }
    
    // Small shimmer particles
    Repeater {
        model: 35
        
        Rectangle {
            property real particleSize: Math.random() * 3 + 1
            property real baseOpacity: Math.random() * 0.6 + 0.2
            property real animationSpeed: Math.random() * 8000 + 4000
            
            x: Math.random() * parent.width
            y: Math.random() * parent.height
            width: particleSize
            height: particleSize
            radius: particleSize / 2
            color: "#87ceeb"  // Light blue
            opacity: baseOpacity
            
            // Glow effect
            layer.enabled: true
            layer.effect: MultiEffect {
                blurEnabled: true
                blurMax: 6
                blur: 0.6
            }
            
            // Gentle movement
            SequentialAnimation on x {
                running: true
                loops: Animation.Infinite
                NumberAnimation {
                    to: parent.x + (Math.random() * 40 - 20)
                    duration: parent.animationSpeed
                    easing.type: Easing.InOutSine
                }
                NumberAnimation {
                    to: parent.x
                    duration: parent.animationSpeed
                    easing.type: Easing.InOutSine
                }
            }
            
            // Shimmer effect
            SequentialAnimation on opacity {
                running: true
                loops: Animation.Infinite
                NumberAnimation {
                    to: parent.baseOpacity * 0.1
                    duration: Math.random() * 2000 + 1000
                    easing.type: Easing.InOutQuad
                }
                NumberAnimation {
                    to: parent.baseOpacity * 1.8
                    duration: Math.random() * 2000 + 1000
                    easing.type: Easing.InOutQuad
                }
            }
        }
    }
    
    // Ambient glow overlay
    Rectangle {
        anchors.centerIn: parent
        width: parent.width * 1.5
        height: parent.height * 1.5
        radius: Math.max(width, height) / 2
        opacity: 0.03
        color: "#00d4ff"
        
        SequentialAnimation on opacity {
            running: true
            loops: Animation.Infinite
            NumberAnimation { to: 0.08; duration: 6000; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 0.02; duration: 6000; easing.type: Easing.InOutQuad }
        }
        
        layer.enabled: true
        layer.effect: MultiEffect {
            blurEnabled: true
            blurMax: 80
            blur: 1.0
        }
    }
}


