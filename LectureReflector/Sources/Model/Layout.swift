import Foundation
import CoreGraphics

/// Composited output layouts. Switchable live while recording; the canvas
/// size is frozen when recording starts (an MP4 track can't change size), so
/// layouts render adaptively into whatever canvas is active.
enum Layout: String, CaseIterable, Identifiable {
    case rectanglePiP = "Rectangle PiP"
    case circlePiP = "Circle PiP"
    case sidebar = "Sidebar"
    case floatingTorso = "Floating Torso"
    case slidesOnly = "Slides Only"
    case cameraOnly = "Camera Only"

    var id: String { rawValue }

    /// Natural output size: sidebar extends the frame so slides keep their
    /// full 16:9 area next to the lecturer panel.
    var canvasSize: CGSize {
        self == .sidebar ? CGSize(width: 1600, height: 720) : CGSize(width: 1280, height: 720)
    }

    var systemImage: String {
        switch self {
        case .rectanglePiP: return "rectangle.inset.bottomright.filled"
        case .circlePiP: return "circle.bottomrighthalf.pattern.checkered"
        case .sidebar: return "sidebar.right"
        case .floatingTorso: return "person.and.background.dotted"
        case .slidesOnly: return "rectangle.fill"
        case .cameraOnly: return "person.fill"
        }
    }
}

struct LectureReflectorError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension Layout {
    /// Layouts where the lecturer floats over the slides and can be moved and resized.
    var hasMovableLecturer: Bool {
        self == .rectanglePiP || self == .circlePiP || self == .floatingTorso
    }

    /// Layouts where the slides sit on a plain canvas and can be moved and resized.
    var hasMovableSlides: Bool {
        hasMovableLecturer || self == .slidesOnly
    }

    /// Width ÷ height of the lecturer box.
    var lecturerAspect: CGFloat {
        switch self {
        case .circlePiP: return 1
        case .floatingTorso: return 450.0 / 510.0
        default: return 4.0 / 3.0
        }
    }

    /// Where the lecturer sits before the user moves it (matches v0.1).
    var defaultPlacement: LecturerPlacement {
        switch self {
        case .circlePiP:
            return LecturerPlacement(x: (1280 - 240 - 24) / 1280, y: (720 - 24 - 240) / 720, width: 240 / 1280)
        case .floatingTorso:
            return LecturerPlacement(x: (1280 - 470) / 1280, y: (720 - 510) / 720, width: 450 / 1280)
        default:
            return LecturerPlacement(x: (1280 - 340 - 24) / 1280, y: (720 - 24 - 255) / 720, width: 340 / 1280)
        }
    }
}

/// Position and size of the lecturer box, as fractions of the output frame
/// with a top-left origin (so it matches what you see in the preview).
/// Height follows from the width and the layout's aspect ratio.
struct LecturerPlacement: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat

    static let minWidth: CGFloat = 0.08
    static let maxWidth: CGFloat = 0.9

    /// Rect in canvas pixels, top-left origin.
    func rect(in canvas: CGSize, aspect: CGFloat) -> CGRect {
        let w = width * canvas.width
        let h = w / aspect
        return CGRect(x: x * canvas.width, y: y * canvas.height, width: w, height: h)
    }

    /// Slides fill the whole frame by default.
    static let fullFrame = LecturerPlacement(x: 0, y: 0, width: 1)

    /// Keeps the box a sensible size and fully inside the frame.
    func clamped(canvas: CGSize, aspect: CGFloat, maxWidth: CGFloat = LecturerPlacement.maxWidth) -> LecturerPlacement {
        var result = self
        let maxByHeight = canvas.height * aspect / canvas.width
        result.width = min(max(width, Self.minWidth), maxWidth, maxByHeight)
        let heightFraction = result.width * canvas.width / aspect / canvas.height
        result.x = min(max(x, 0), 1 - result.width)
        result.y = min(max(y, 0), 1 - heightFraction)
        return result
    }
}
