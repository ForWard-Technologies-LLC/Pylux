// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Parses Android vector `pathData` (SVG path subset) for Chiaki control drawables.

import CoreGraphics
import UIKit

/// Chiaki `control_button_*` vectors sharing viewport 67.73333 (shoulders L1/L2/R1/R2 + sticks L3/R3).
enum ChiakiShoulderVector {
    static let viewport: CGFloat = 67.73333

    /// Idle geometry matches pressed; only fill color differs on Android.
    static let l1 = """
    M39.2255,0 L0,39.2255 20.3838,59.6093a27.7366,27.7366 88.4859,0 0,39.2255 0,27.7366 27.7366,88.4859 0,0 0,-39.2255zM25.4129,29.4287l2.7735,0l0,18.1643l9.9818,0l0,2.3342L25.4129,49.9272ZM46.3098,29.4287l2.7735,0l0,18.1643l4.5305,0l0,2.3342l-11.8076,0l0,-2.3342l4.531,0l0,-15.6383l-4.9289,0.9886l0,-2.5259z
    """

    static let l2 = """
    m27.6526,0a27.7366,27.7366 88.4859,0 0,-19.5285 8.1241,27.7366 27.7366,88.4859 0,0 0,39.2255L28.5078,67.7333 67.7333,28.5078 47.3496,8.1241A27.7366,27.7366 88.4859,0 0,27.6526 0ZM34.9017,15.1846c2.1235,0 3.8172,0.5309 5.0803,1.5927 1.2631,1.0618 1.8945,2.4804 1.8945,4.2561 0,0.8421 -0.1602,1.6432 -0.4806,2.403 -0.3112,0.7506 -0.8832,1.6383 -1.7162,2.6634 -0.2288,0.2654 -0.9563,1.034 -2.1828,2.3063 -1.2265,1.2631 -2.9565,3.0342 -5.1899,5.3134l9.6795,0l0,2.3342l-13.0157,0l0,-2.3342c1.0526,-1.0892 2.4851,-2.549 4.2974,-4.3796 1.8215,-1.8398 2.9655,-3.025 3.4323,-3.5559 0.8879,-0.9977 1.5058,-1.84 1.8536,-2.5265 0.357,-0.6956 0.5354,-1.3777 0.5354,-2.0459 0,-1.0892 -0.3846,-1.9769 -1.1534,-2.6634 -0.7597,-0.6865 -1.7526,-1.0299 -2.9791,-1.0299 -0.8695,-0 -1.7898,0.1511 -2.76,0.4532 -0.9611,0.3021 -1.9908,0.7598 -3.0892,1.373L29.1078,16.5437c1.1167,-0.4485 2.1603,-0.7871 3.1306,-1.016 0.9702,-0.2288 1.8579,-0.3431 2.6634,-0.3431zM14.0053,15.5551l2.7735,0l0,18.1643l9.9813,0l0,2.3342L14.0053,36.0536Z
    """

    static let r1 = """
    M28.5078,0 L8.1241,20.3838a27.7366,27.7366 88.4859,0 0,0 39.2255,27.7366 27.7366,88.4859 0,0 39.2255,0L67.7333,39.2255ZM12.4178,29.4287l6.2606,0c2.3432,0 4.0913,0.4898 5.2446,1.4692 1.1533,0.9794 1.7301,2.4573 1.7301,4.4344 0,1.2906 -0.3018,2.3615 -0.9059,3.2127 -0.595,0.8512 -1.4645,1.442 -2.6086,1.7715 0.595,0.2014 1.1713,0.6313 1.7296,1.2904 0.5675,0.659 1.1352,1.5654 1.7027,2.7187L28.3853,49.9272L25.4062,49.9272l-2.6226,-5.2586C22.1063,43.2956 21.4472,42.385 20.8065,41.9365c-0.6316,-0.4485 -1.4963,-0.6728 -2.5947,-0.6728L15.1913,41.2636l0,8.6636L12.4178,49.9272ZM37.1864,29.4287l2.7735,0l0,18.1643l4.5305,0l0,2.3342l-11.8075,0l0,-2.3342l4.531,0l0,-15.6383l-4.9289,0.9886l0,-2.5259zM15.1913,31.7076l0,7.2766l3.4871,0c1.3364,0 2.3432,-0.3066 3.0205,-0.9198 0.6865,-0.6224 1.0299,-1.5331 1.0299,-2.7321 0,-1.1991 -0.3434,-2.1006 -1.0299,-2.7047 -0.6773,-0.6133 -1.6841,-0.9198 -3.0205,-0.9198z
    """

    static let r2 = """
    M20.3838,8.1241 L0,28.5078 39.2255,67.7333 59.6093,47.3496a27.7366,27.7366 88.4859,0 0,0 -39.2255,27.7366 27.7366,88.4859 0,0 -39.2255,0zM48.9278,15.1846c2.1235,0 3.8167,0.5309 5.0798,1.5927 1.2631,1.0618 1.895,2.4804 1.895,4.2561 0,0.8421 -0.1602,1.6432 -0.4806,2.403 -0.3112,0.7506 -0.8832,1.6383 -1.7162,2.6634 -0.2288,0.2654 -0.9568,1.034 -2.1833,2.3063 -1.2265,1.2631 -2.956,3.0342 -5.1893,5.3134l9.679,0l0,2.3342l-13.0157,0l0,-2.3342c1.0526,-1.0892 2.4851,-2.549 4.2974,-4.3796 1.8215,-1.8398 2.9655,-3.025 3.4323,-3.5559 0.8879,-0.9977 1.5058,-1.84 1.8536,-2.5265 0.357,-0.6956 0.5354,-1.3777 0.5354,-2.0459 0,-1.0892 -0.384,-1.9769 -1.1529,-2.6634 -0.7597,-0.6865 -1.7531,-1.0299 -2.9797,-1.0299 -0.8695,-0 -1.7893,0.1511 -2.7595,0.4532 -0.9611,0.3021 -1.9908,0.7598 -3.0892,1.373L43.1338,16.5437c1.1167,-0.4485 2.1603,-0.7871 3.1306,-1.016 0.9702,-0.2288 1.8579,-0.3431 2.6634,-0.3431zM24.1593,15.5551l6.2611,0c2.3432,0 4.0913,0.4898 5.2446,1.4692 1.1533,0.9794 1.7296,2.4578 1.7296,4.4349 0,1.2906 -0.3018,2.3615 -0.9059,3.2127 -0.595,0.8512 -1.4645,1.4414 -2.6086,1.771 0.595,0.2014 1.1713,0.6313 1.7296,1.2904 0.5675,0.659 1.1352,1.5654 1.7027,2.7187l2.8148,5.6017l-2.9797,0l-2.6221,-5.2586c-0.6773,-1.373 -1.3364,-2.2836 -1.9771,-2.7321 -0.6316,-0.4485 -1.4968,-0.6728 -2.5952,-0.6728l-3.0205,0l0,8.6636L24.1593,36.0536ZM26.9327,17.8346l0,7.2766l3.4876,0c1.3364,0 2.3432,-0.3066 3.0205,-0.9198 0.6865,-0.6224 1.0294,-1.5331 1.0294,-2.7321 0,-1.1991 -0.3429,-2.1006 -1.0294,-2.7047 -0.6773,-0.6133 -1.6841,-0.9198 -3.0205,-0.9198z
    """

    static let l3 = "M0,0 L-41.939,102.093 67.7333,67.7333C67.7333,30.3253 37.4081,0 0,0ZM33.6093,31.3252c2.1052,0 3.7711,0.4807 4.9976,1.4418 1.2265,0.9519 1.8397,2.2423 1.8397,3.8716 0,1.135 -0.3253,2.0964 -0.9751,2.8835 -0.6499,0.778 -1.5739,1.318 -2.773,1.6201 1.3272,0.2837 2.3613,0.8739 3.1027,1.771 0.7506,0.897 1.126,2.0047 1.126,3.3228 0,2.0228 -0.6959,3.5878 -2.0872,4.6953 -1.3913,1.1075 -3.368,1.6614 -5.9309,1.6614 -0.8604,0 -1.7486,-0.0871 -2.6639,-0.261 -0.9062,-0.1648 -1.8441,-0.4163 -2.8143,-0.755l0,-2.6774c0.7689,0.4485 1.6106,0.7871 2.5259,1.016 0.9153,0.2288 1.8719,0.3431 2.8696,0.3431 1.7391,0 3.0621,-0.3434 3.9682,-1.0299 0.9153,-0.6865 1.3725,-1.6837 1.3725,-2.9926 0,-1.2082 -0.4252,-2.1514 -1.2764,-2.8288 -0.8421,-0.6865 -2.0187,-1.0294 -3.529,-1.0294l-2.3885,0l0,-2.2794l2.4986,0c1.3638,0 2.4075,-0.2697 3.1306,-0.8098 0.7231,-0.5492 1.0847,-1.3365 1.0847,-2.3616 0,-1.0526 -0.3755,-1.858 -1.126,-2.4164 -0.7414,-0.5675 -1.808,-0.8511 -3.1993,-0.8511 -0.7597,0 -1.5742,0.0823 -2.4438,0.247 -0.8695,0.1648 -1.8261,0.4211 -2.8696,0.7689l0,-2.4717c1.0526,-0.2929 2.037,-0.5124 2.9523,-0.6589 0.9245,-0.1464 1.794,-0.2196 2.6086,-0.2196zM12.3832,31.6957l2.7735,0l0,18.1648l9.9813,0l0,2.3337L12.3832,52.1942Z"

    static let r3 = "M67.7333,0C30.3252,0 0,30.3252 0,67.7333l109.6724,34.3597zM50.2982,31.3252c2.1052,0 3.7711,0.4807 4.9976,1.4418 1.2265,0.9519 1.8402,2.2423 1.8402,3.8716 0,1.135 -0.3253,2.0964 -0.9751,2.8835 -0.6499,0.778 -1.5744,1.318 -2.7735,1.6201 1.3272,0.2837 2.3618,0.8739 3.1032,1.771 0.7506,0.897 1.1255,2.0047 1.1255,3.3228 0,2.0228 -0.6954,3.5878 -2.0867,4.6953 -1.3913,1.1075 -3.3685,1.6614 -5.9314,1.6614 -0.8604,0 -1.7481,-0.0871 -2.6634,-0.261 -0.9062,-0.1648 -1.8441,-0.4163 -2.8143,-0.755l0,-2.6774c0.7689,0.4485 1.6106,0.7871 2.5259,1.016 0.9153,0.2288 1.8719,0.3431 2.8696,0.3431 1.7391,0 3.0616,-0.3434 3.9677,-1.0299 0.9153,-0.6865 1.373,-1.6837 1.373,-2.9926 0,-1.2082 -0.4257,-2.1514 -1.2769,-2.8288 -0.8421,-0.6865 -2.0182,-1.0294 -3.5285,-1.0294l-2.389,0l0,-2.2794l2.4991,0c1.3638,0 2.4069,-0.2697 3.13,-0.8098 0.7231,-0.5492 1.0847,-1.3365 1.0847,-2.3616 0,-1.0526 -0.375,-1.858 -1.1255,-2.4164 -0.7414,-0.5675 -1.808,-0.8511 -3.1993,-0.8511 -0.7597,0 -1.5742,0.0823 -2.4438,0.247 -0.8695,0.1648 -1.8261,0.4211 -2.8696,0.7689l0,-2.4717c1.0526,-0.2929 2.0364,-0.5124 2.9518,-0.6589 0.9245,-0.1464 1.794,-0.2196 2.6086,-0.2196zM25.2005,31.6957L31.4611,31.6957c2.3432,0 4.0913,0.4898 5.2446,1.4692 1.1533,0.9794 1.7301,2.4578 1.7301,4.4349 0,1.2906 -0.3018,2.3615 -0.9059,3.2127 -0.595,0.8512 -1.4645,1.4414 -2.6086,1.771 0.595,0.2014 1.1713,0.6319 1.7296,1.2909 0.5675,0.659 1.1352,1.5649 1.7027,2.7182l2.8143,5.6017l-2.9791,0l-2.6226,-5.2581c-0.6773,-1.373 -1.3364,-2.2841 -1.9771,-2.7326 -0.6316,-0.4485 -1.4963,-0.6723 -2.5947,-0.6723l-3.0205,0l0,8.663L25.2005,52.1942ZM27.974,33.9752l0,7.2766l3.4871,0c1.3364,0 2.3432,-0.3066 3.0205,-0.9198 0.6865,-0.6224 1.0299,-1.5331 1.0299,-2.7321 0,-1.1991 -0.3434,-2.1006 -1.0299,-2.7047 -0.6773,-0.6133 -1.6841,-0.9198 -3.0205,-0.9198z"


    /// Uniform scale: map the square viewport into the drawable rect (Android ButtonView).

    static func path(_ data: String, in rect: CGRect) -> UIBezierPath {
        let raw = ControlSVGPathParser.cgPath(pathData: data)
        let s = min(rect.width, rect.height) / viewport
        let ox = rect.minX + (rect.width - viewport * s) * 0.5
        let oy = rect.minY + (rect.height - viewport * s) * 0.5
        let t = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: ox, ty: oy)
        let p = CGMutablePath()
        p.addPath(raw, transform: t)
        return UIBezierPath(cgPath: p)
    }

    /// Filled Chiaki shoulder path only (no stroke — same-color stroke on translucent fills reads as a bright outline).
    static func drawShoulder(_ data: String, in rect: CGRect, fill: UIColor) {
        let bp = path(data, in: rect)
        fill.setFill()
        bp.fill()
    }
}

// MARK: - Parser (M L H V C A Z; m l h v c a z)

private enum ControlSVGPathParser {
    static func cgPath(pathData: String) -> CGPath {
        let chars = Array(pathData)
        var i = 0
        let path = CGMutablePath()
        var cur = CGPoint.zero
        var subStart = CGPoint.zero
        var lastCmd: Character = "M"

        func skipSep() {
            while i < chars.count {
                let c = chars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "," { i += 1 } else { break }
            }
        }

        func peek() -> Character? { i < chars.count ? chars[i] : nil }

        func readNumber() -> CGFloat? {
            skipSep()
            guard i < chars.count else { return nil }
            let start = i
            if chars[i] == "-" || chars[i] == "+" { i += 1 }
            var saw = false
            while i < chars.count {
                let c = chars[i]
                if c.isWholeNumber || c == "." {
                    saw = true
                    i += 1
                } else { break }
            }
            guard saw, start < i else { return nil }
            return CGFloat(Double(String(chars[start..<i])) ?? 0)
        }

        func startsNumber() -> Bool {
            skipSep()
            guard let c = peek() else { return false }
            return c.isWholeNumber || c == "." || c == "-" || c == "+"
        }

        func readCmd() -> Character? {
            skipSep()
            guard i < chars.count else { return nil }
            let c = chars[i]
            let cmds = "MmLlHhVvCcZzAa"
            guard cmds.contains(c) else { return nil }
            i += 1
            return c
        }

        func map(_ x: CGFloat, _ y: CGFloat, rel: Bool) -> CGPoint {
            rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
        }

        func lineTo(_ p: CGPoint) {
            path.addLine(to: p)
            cur = p
        }

        func addArc(rx: CGFloat, ry: CGFloat, rotDeg: CGFloat, large: Bool, sweep: Bool, ex: CGFloat, ey: CGFloat, rel: Bool) {
            let end = map(ex, ey, rel: rel)
            addSvgArc(path: path, cur: &cur, rx: rx, ry: ry, rotationDeg: rotDeg, largeArc: large, sweep: sweep, end: end)
        }

        while i < chars.count {
            skipSep()
            if i >= chars.count { break }

            let cmdChar: Character
            if let c = peek(), "MmLlHhVvCcZzAa".contains(c) {
                guard let nc = readCmd() else { break }
                cmdChar = nc
                lastCmd = cmdChar
            } else {
                guard lastCmd != "z" && lastCmd != "Z" else { break }
                cmdChar = lastCmd
            }

            let rel = cmdChar.isLowercase
            guard let cmdUpper = String(cmdChar).uppercased().first else { break }

            switch cmdUpper {
            case "M":
                guard let x0 = readNumber(), let y0 = readNumber() else { break }
                var p = map(x0, y0, rel: rel)
                path.move(to: p)
                cur = p
                subStart = p
                lastCmd = rel ? "l" : "L"
                while startsNumber(), let xa = readNumber(), let ya = readNumber() {
                    p = map(xa, ya, rel: rel)
                    path.addLine(to: p)
                    cur = p
                }
            case "L":
                guard let x = readNumber(), let y = readNumber() else { break }
                lineTo(map(x, y, rel: rel))
                while startsNumber(), let xa = readNumber(), let ya = readNumber() {
                    lineTo(map(xa, ya, rel: rel))
                }
            case "H":
                guard let x = readNumber() else { break }
                let nx = rel ? cur.x + x : x
                lineTo(CGPoint(x: nx, y: cur.y))
                while startsNumber(), let xa = readNumber() {
                    let xx = rel ? cur.x + xa : xa
                    lineTo(CGPoint(x: xx, y: cur.y))
                }
            case "V":
                guard let y = readNumber() else { break }
                let ny = rel ? cur.y + y : y
                lineTo(CGPoint(x: cur.x, y: ny))
                while startsNumber(), let ya = readNumber() {
                    let yy = rel ? cur.y + ya : ya
                    lineTo(CGPoint(x: cur.x, y: yy))
                }
            case "C":
                guard let x1 = readNumber(), let y1 = readNumber(),
                      let x2 = readNumber(), let y2 = readNumber(),
                      let x3 = readNumber(), let y3 = readNumber() else { break }
                let cp1 = map(x1, y1, rel: rel)
                let cp2 = map(x2, y2, rel: rel)
                let ep = map(x3, y3, rel: rel)
                path.addCurve(to: ep, control1: cp1, control2: cp2)
                cur = ep
                while startsNumber(),
                      let xa = readNumber(), let ya = readNumber(),
                      let xb = readNumber(), let yb = readNumber(),
                      let xc = readNumber(), let yc = readNumber() {
                    let c1 = map(xa, ya, rel: rel)
                    let c2 = map(xb, yb, rel: rel)
                    let e = map(xc, yc, rel: rel)
                    path.addCurve(to: e, control1: c1, control2: c2)
                    cur = e
                }
            case "A":
                guard let rx = readNumber(), let ry = readNumber(), let rot = readNumber(),
                      let la = readNumber(), let sw = readNumber(),
                      let ex = readNumber(), let ey = readNumber() else { break }
                addArc(rx: rx, ry: ry, rotDeg: rot, large: la != 0, sweep: sw != 0, ex: ex, ey: ey, rel: rel)
                lastCmd = cmdChar
                while startsNumber(),
                      let nrx = readNumber(), let nry = readNumber(), let nrot = readNumber(),
                      let nla = readNumber(), let nsw = readNumber(),
                      let nex = readNumber(), let ney = readNumber() {
                    addArc(rx: nrx, ry: nry, rotDeg: nrot, large: nla != 0, sweep: nsw != 0, ex: nex, ey: ney, rel: rel)
                }
            case "Z":
                path.closeSubpath()
                cur = subStart
                lastCmd = cmdChar
            default:
                i += 1
            }
        }

        return path
    }
}

// MARK: - SVG elliptical arc (F.6.5)

private func addSvgArc(
    path: CGMutablePath,
    cur: inout CGPoint,
    rx: CGFloat,
    ry: CGFloat,
    rotationDeg: CGFloat,
    largeArc: Bool,
    sweep: Bool,
    end: CGPoint
) {
    let x1 = cur.x, y1 = cur.y
    let x2 = end.x, y2 = end.y
    if x1 == x2 && y1 == y2 { return }

    var rx = abs(rx)
    var ry = abs(ry)
    if rx < 1e-10 || ry < 1e-10 {
        path.addLine(to: end)
        cur = end
        return
    }

    let phi = rotationDeg * .pi / 180
    let cosPhi = cos(phi)
    let sinPhi = sin(phi)

    let dx2 = (x1 - x2) * 0.5
    let dy2 = (y1 - y2) * 0.5
    let x1p = cosPhi * dx2 + sinPhi * dy2
    let y1p = -sinPhi * dx2 + cosPhi * dy2

    var rxSq = rx * rx
    var rySq = ry * ry
    let x1pSq = x1p * x1p
    let y1pSq = y1p * y1p
    var lambda = x1pSq / rxSq + y1pSq / rySq
    if lambda > 1 {
        let sl = sqrt(lambda)
        rx *= sl
        ry *= sl
        rxSq = rx * rx
        rySq = ry * ry
    }

    let sign: CGFloat = largeArc == sweep ? -1 : 1
    var sq = (rxSq * rySq - rxSq * y1pSq - rySq * x1pSq) / (rxSq * y1pSq + rySq * x1pSq)
    if sq < 0 { sq = 0 }
    sq = sqrt(sq)
    let cxp = sign * sq * rx * y1p / ry
    let cyp = sign * -sq * ry * x1p / rx

    let cx = cosPhi * cxp - sinPhi * cyp + (x1 + x2) * 0.5
    let cy = sinPhi * cxp + cosPhi * cyp + (y1 + y2) * 0.5

    func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
        let n = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
        if n < 1e-10 { return 0 }
        var t = (ux * vx + uy * vy) / n
        t = max(-1, min(1, t))
        let a = acos(t)
        return (ux * vy - uy * vx) < 0 ? -a : a
    }

    let ux = (x1p - cxp) / rx
    let uy = (y1p - cyp) / ry
    let vx = (-x1p - cxp) / rx
    let vy = (-y1p - cyp) / ry
    let theta1 = angle(1, 0, ux, uy)
    var delta = angle(ux, uy, vx, vy)
    if !sweep, delta > 0 { delta -= 2 * .pi }
    if sweep, delta < 0 { delta += 2 * .pi }

    let segments = max(1, Int(ceil(abs(delta) / (.pi * 0.5 + 0.001))))
    let step = delta / CGFloat(segments)
    let tt = tan(step * 0.25)
    let alpha = sin(step) * (sqrt(4 + 3 * tt * tt) - 1) / 3

    var px = x1
    var py = y1
    var a1 = theta1

    for _ in 0 ..< segments {
        let cos1 = cos(a1)
        let sin1 = sin(a1)
        let a2 = a1 + step
        let cos2 = cos(a2)
        let sin2 = sin(a2)

        let ex2 = cosPhi * rx * cos2 - sinPhi * ry * sin2 + cx
        let ey2 = sinPhi * rx * cos2 + cosPhi * ry * sin2 + cy

        let d1x = -cosPhi * rx * sin1 - sinPhi * ry * cos1
        let d1y = -sinPhi * rx * sin1 + cosPhi * ry * cos1
        let d2x = -cosPhi * rx * sin2 - sinPhi * ry * cos2
        let d2y = -sinPhi * rx * sin2 + cosPhi * ry * cos2

        let c1x = px + alpha * d1x
        let c1y = py + alpha * d1y
        let c2x = ex2 - alpha * d2x
        let c2y = ey2 - alpha * d2y

        path.addCurve(to: CGPoint(x: ex2, y: ey2), control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
        px = ex2
        py = ey2
        a1 = a2
    }

    cur = end
}
