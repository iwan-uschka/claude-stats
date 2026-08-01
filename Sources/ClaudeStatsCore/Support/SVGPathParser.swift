import CoreGraphics
import Foundation

/// Failure modes of ``SVGPathParser``.
public enum SVGPathParseError: Error, Equatable {
    /// A character appeared where a command letter or a number was expected.
    case unexpectedCharacter(Character, offset: Int)
    /// A command ran out of arguments.
    case missingNumber(command: Character, offset: Int)
    /// An arc's large-arc/sweep flag was not `0` or `1`.
    case invalidFlag(command: Character, offset: Int)
    /// The path data started with something other than a `moveto`.
    case missingInitialMoveTo(offset: Int)
}

/// Minimal SVG `path`-`d` parser producing a `CGPath`.
///
/// Supports the full SVG 1.1 path grammar used by hand-authored icon marks:
/// `M m L l H h V v C c S s Q q T t A a Z z`, implicit repeated argument sets,
/// and comma-or-whitespace separators. Coordinates are taken verbatim in SVG
/// user space (y grows downward), which matches SwiftUI's `Path` coordinate
/// space — so no flip is needed for SwiftUI, while AppKit drawing should use a
/// flipped context.
///
/// This is deliberately a parser rather than a build-time rasterisation step:
/// the mark stays vector (crisp at any menu bar scale and in the generated app
/// icon sizes), the package keeps no binary blobs or resource bundle to load,
/// and the whole thing is pure enough to unit test.
public enum SVGPathParser {
    /// Parses SVG path data into a `CGPath` in SVG user-space coordinates.
    public static func cgPath(from pathData: String) throws -> CGPath {
        var scanner = Scanner(pathData)
        let path = CGMutablePath()

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        /// Reflection anchor for `S`/`s` (cubic) and `T`/`t` (quadratic).
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character?
        var hasStarted = false

        func number(_ command: Character) throws -> Double {
            guard let value = scanner.takeNumber() else {
                throw SVGPathParseError.missingNumber(command: command, offset: scanner.offset)
            }
            return value
        }

        func flag(_ command: Character) throws -> Bool {
            guard let value = scanner.takeFlag() else {
                throw SVGPathParseError.invalidFlag(command: command, offset: scanner.offset)
            }
            return value
        }

        /// Resolves a coordinate pair against `current` for lowercase commands.
        func point(_ x: Double, _ y: Double, relative: Bool) -> CGPoint {
            relative
                ? CGPoint(x: current.x + x, y: current.y + y)
                : CGPoint(x: x, y: y)
        }

        while true {
            scanner.skipSeparators()
            if scanner.isAtEnd { break }

            if let letter = scanner.takeCommand() {
                command = letter
            } else if let previous = command {
                // Implicit repeat of the previous command's argument set. A
                // repeated `moveto` degrades to `lineto`, per the spec.
                switch previous {
                case "M": command = "L"
                case "m": command = "l"
                default: command = previous
                }
            } else if let character = scanner.peek() {
                throw SVGPathParseError.unexpectedCharacter(character, offset: scanner.offset)
            } else {
                break
            }

            guard let active = command else { break }
            let relative = active.isLowercase

            if !hasStarted, active != "M", active != "m" {
                throw SVGPathParseError.missingInitialMoveTo(offset: scanner.offset)
            }

            switch active {
            case "M", "m":
                let target = point(try number(active), try number(active), relative: relative)
                path.move(to: target)
                current = target
                subpathStart = target
                lastCubicControl = nil
                lastQuadControl = nil
                hasStarted = true

            case "L", "l":
                let target = point(try number(active), try number(active), relative: relative)
                path.addLine(to: target)
                current = target
                lastCubicControl = nil
                lastQuadControl = nil

            case "H", "h":
                let x = try number(active)
                let target = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: target)
                current = target
                lastCubicControl = nil
                lastQuadControl = nil

            case "V", "v":
                let y = try number(active)
                let target = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: target)
                current = target
                lastCubicControl = nil
                lastQuadControl = nil

            case "C", "c":
                let control1 = point(try number(active), try number(active), relative: relative)
                let control2 = point(try number(active), try number(active), relative: relative)
                let target = point(try number(active), try number(active), relative: relative)
                path.addCurve(to: target, control1: control1, control2: control2)
                current = target
                lastCubicControl = control2
                lastQuadControl = nil

            case "S", "s":
                let control1 = reflect(lastCubicControl, about: current)
                let control2 = point(try number(active), try number(active), relative: relative)
                let target = point(try number(active), try number(active), relative: relative)
                path.addCurve(to: target, control1: control1, control2: control2)
                current = target
                lastCubicControl = control2
                lastQuadControl = nil

            case "Q", "q":
                let control = point(try number(active), try number(active), relative: relative)
                let target = point(try number(active), try number(active), relative: relative)
                path.addQuadCurve(to: target, control: control)
                current = target
                lastQuadControl = control
                lastCubicControl = nil

            case "T", "t":
                let control = reflect(lastQuadControl, about: current)
                let target = point(try number(active), try number(active), relative: relative)
                path.addQuadCurve(to: target, control: control)
                current = target
                lastQuadControl = control
                lastCubicControl = nil

            case "A", "a":
                let radiusX = try number(active)
                let radiusY = try number(active)
                let rotation = try number(active)
                let largeArc = try flag(active)
                let sweep = try flag(active)
                let target = point(try number(active), try number(active), relative: relative)
                appendArc(
                    to: path,
                    from: current,
                    to: target,
                    radiusX: radiusX,
                    radiusY: radiusY,
                    rotationDegrees: rotation,
                    largeArc: largeArc,
                    sweep: sweep
                )
                current = target
                lastCubicControl = nil
                lastQuadControl = nil

            case "Z", "z":
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil
                lastQuadControl = nil

            default:
                throw SVGPathParseError.unexpectedCharacter(active, offset: scanner.offset)
            }
        }

        return path.copy() ?? path
    }

    /// Reflection of the previous control point through `anchor`; the anchor
    /// itself when there is no previous control point (spec behaviour).
    private static func reflect(_ control: CGPoint?, about anchor: CGPoint) -> CGPoint {
        guard let control else { return anchor }
        return CGPoint(x: 2 * anchor.x - control.x, y: 2 * anchor.y - control.y)
    }

    /// Endpoint-parameterised elliptical arc → cubic Béziers, following the
    /// SVG 1.1 implementation notes (F.6.5), split into ≤90° segments.
    private static func appendArc(
        to path: CGMutablePath,
        from start: CGPoint,
        to end: CGPoint,
        radiusX: Double,
        radiusY: Double,
        rotationDegrees: Double,
        largeArc: Bool,
        sweep: Bool
    ) {
        if start == end { return }

        var rx = abs(radiusX)
        var ry = abs(radiusY)
        guard rx > 0, ry > 0 else {
            path.addLine(to: end)
            return
        }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        let dx2 = (start.x - end.x) / 2
        let dy2 = (start.y - end.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        // Scale up under-sized radii so a solution exists.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = lambda.squareRoot()
            rx *= scale
            ry *= scale
        }

        let rx2 = rx * rx
        let ry2 = ry * ry
        let numerator = max(0, rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p)
        let denominator = rx2 * y1p * y1p + ry2 * x1p * x1p
        let coefficient = denominator > 0 ? (numerator / denominator).squareRoot() : 0
        let sign: Double = (largeArc != sweep) ? 1 : -1
        let cxp = sign * coefficient * (rx * y1p / ry)
        let cyp = sign * coefficient * -(ry * x1p / rx)

        let centerX = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let centerY = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        let startVector = CGPoint(x: (x1p - cxp) / rx, y: (y1p - cyp) / ry)
        let endVector = CGPoint(x: (-x1p - cxp) / rx, y: (-y1p - cyp) / ry)

        let theta1 = atan2(startVector.y, startVector.x)
        var deltaTheta = atan2(endVector.y, endVector.x) - theta1
        if !sweep, deltaTheta > 0 {
            deltaTheta -= 2 * .pi
        } else if sweep, deltaTheta < 0 {
            deltaTheta += 2 * .pi
        }

        let segmentCount = max(1, Int((abs(deltaTheta) / (.pi / 2)).rounded(.up)))
        let segmentAngle = deltaTheta / Double(segmentCount)
        let alpha = 4.0 / 3.0 * tan(segmentAngle / 4)

        func ellipsePoint(_ theta: Double) -> CGPoint {
            CGPoint(
                x: centerX + rx * cos(theta) * cosPhi - ry * sin(theta) * sinPhi,
                y: centerY + rx * cos(theta) * sinPhi + ry * sin(theta) * cosPhi
            )
        }

        func ellipseDerivative(_ theta: Double) -> CGPoint {
            CGPoint(
                x: -rx * sin(theta) * cosPhi - ry * cos(theta) * sinPhi,
                y: -rx * sin(theta) * sinPhi + ry * cos(theta) * cosPhi
            )
        }

        for segment in 0..<segmentCount {
            let thetaA = theta1 + Double(segment) * segmentAngle
            let thetaB = thetaA + segmentAngle
            let pointA = ellipsePoint(thetaA)
            let pointB = ellipsePoint(thetaB)
            let derivativeA = ellipseDerivative(thetaA)
            let derivativeB = ellipseDerivative(thetaB)

            path.addCurve(
                to: segment == segmentCount - 1 ? end : pointB,
                control1: CGPoint(
                    x: pointA.x + alpha * derivativeA.x,
                    y: pointA.y + alpha * derivativeA.y
                ),
                control2: CGPoint(
                    x: pointB.x - alpha * derivativeB.x,
                    y: pointB.y - alpha * derivativeB.y
                )
            )
        }
    }
}

// MARK: - Scanner

extension SVGPathParser {
    /// Character scanner for SVG path data.
    ///
    /// Numbers and command letters need separate handling from the arc flags:
    /// `0 01-.104` is a valid flag pair followed by a coordinate, so flags are
    /// read one character at a time rather than through the number scanner.
    fileprivate struct Scanner {
        private let characters: [Character]
        private var index: Int = 0

        private static let commandLetters: Set<Character> = [
            "M", "m", "L", "l", "H", "h", "V", "v",
            "C", "c", "S", "s", "Q", "q", "T", "t",
            "A", "a", "Z", "z",
        ]

        init(_ string: String) {
            characters = Array(string)
        }

        var isAtEnd: Bool { index >= characters.count }
        var offset: Int { index }

        func peek() -> Character? {
            index < characters.count ? characters[index] : nil
        }

        mutating func skipSeparators() {
            while let character = peek(), character == "," || character.isWhitespace {
                index += 1
            }
        }

        mutating func takeCommand() -> Character? {
            guard let character = peek(), Self.commandLetters.contains(character) else {
                return nil
            }
            index += 1
            return character
        }

        mutating func takeNumber() -> Double? {
            skipSeparators()
            let start = index
            var sawDigit = false

            if let character = peek(), character == "+" || character == "-" {
                index += 1
            }
            while let character = peek(), character.isASCII, character.isNumber {
                index += 1
                sawDigit = true
            }
            if peek() == "." {
                index += 1
                while let character = peek(), character.isASCII, character.isNumber {
                    index += 1
                    sawDigit = true
                }
            }
            guard sawDigit else {
                index = start
                return nil
            }
            if let character = peek(), character == "e" || character == "E" {
                let beforeExponent = index
                index += 1
                if let sign = peek(), sign == "+" || sign == "-" {
                    index += 1
                }
                var sawExponentDigit = false
                while let character = peek(), character.isASCII, character.isNumber {
                    index += 1
                    sawExponentDigit = true
                }
                if !sawExponentDigit {
                    index = beforeExponent
                }
            }

            return Double(String(characters[start..<index]))
        }

        mutating func takeFlag() -> Bool? {
            skipSeparators()
            switch peek() {
            case "0":
                index += 1
                return false
            case "1":
                index += 1
                return true
            default:
                return nil
            }
        }
    }
}
