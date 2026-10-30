import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Metal
import Vision

/// Merges the latest slide frame and camera frame into one output frame
/// according to the selected layout. GPU-backed via Core Image + Metal.
final class Compositor {
    private let ciContext: CIContext
    private var pools: [String: CVPixelBufferPool] = [:]

    // Person segmentation for the Floating Torso layout.
    private let segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private var lastMask: CIImage?
    private var segmentationTick = 0

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
    }

    /// Returns the rendered pixel buffer (for the encoder) and the CIImage
    /// (so the preview can be generated without re-compositing).
    func composite(
        slide: CVPixelBuffer?,
        camera: CVPixelBuffer?,
        layout: Layout,
        canvasSize: CGSize,
        mirrorCamera: Bool,
        placement: LecturerPlacement,
        slidePlacement: LecturerPlacement
    ) -> (CVPixelBuffer, CIImage)? {
        let frame = CGRect(origin: .zero, size: canvasSize)
        var canvas = CIImage(color: .black).cropped(to: frame)

        let slideImage = slide.map { CIImage(cvPixelBuffer: $0) }
        var cameraImage = camera.map { CIImage(cvPixelBuffer: $0) }
        if mirrorCamera, let image = cameraImage {
            cameraImage = image.oriented(.upMirrored)
        }

        // Slide area (top-left-origin fractions → Core Image's bottom-left origin).
        let canvasAspect = canvasSize.width / canvasSize.height
        let slidePlaced = slidePlacement.clamped(canvas: canvasSize, aspect: canvasAspect, maxWidth: 1)
            .rect(in: canvasSize, aspect: canvasAspect)
        let slideRect = CGRect(
            x: slidePlaced.minX,
            y: frame.height - slidePlaced.maxY,
            width: slidePlaced.width,
            height: slidePlaced.height
        ).integral.intersection(frame)

        switch layout {
        case .slidesOnly:
            if let slideImage {
                canvas = aspectFit(slideImage, in: slideRect).composited(over: canvas)
            }

        case .cameraOnly:
            if let cameraImage {
                canvas = aspectFill(cameraImage, in: frame).composited(over: canvas)
            }

        case .rectanglePiP, .circlePiP, .floatingTorso:
            if let slideImage {
                canvas = aspectFit(slideImage, in: slideRect).composited(over: canvas)
            }
            if let cameraImage {
                // Placement is stored top-left-origin; Core Image is bottom-left.
                let placed = placement.clamped(canvas: canvasSize, aspect: layout.lecturerAspect)
                    .rect(in: canvasSize, aspect: layout.lecturerAspect)
                let lecturerRect = CGRect(
                    x: placed.minX,
                    y: frame.height - placed.maxY,
                    width: placed.width,
                    height: placed.height
                ).integral
                // Corner rounding scales with the box (14 px at the default 340 px).
                let cornerRadius = max(6, lecturerRect.width * 14 / 340)
                switch layout {
                case .rectanglePiP:
                    canvas = pip(cameraImage, in: lecturerRect, cornerRadius: cornerRadius, on: canvas, frame: frame)
                case .circlePiP:
                    canvas = pip(cameraImage, in: lecturerRect, cornerRadius: lecturerRect.width / 2, on: canvas, frame: frame)
                case .floatingTorso:
                    if let cameraBuffer = camera, let mask = personMask(for: cameraBuffer, mirrored: mirrorCamera) {
                        let cutoutFilter = CIFilter.blendWithMask()
                        cutoutFilter.inputImage = cameraImage
                        cutoutFilter.backgroundImage = CIImage(color: .clear).cropped(to: cameraImage.extent)
                        cutoutFilter.maskImage = mask
                        if let cutout = cutoutFilter.outputImage {
                            canvas = aspectFill(cutout, in: lecturerRect).composited(over: canvas)
                        }
                    } else {
                        // Segmentation unavailable: fall back to a rectangle in the same spot.
                        canvas = pip(cameraImage, in: lecturerRect, cornerRadius: cornerRadius, on: canvas, frame: frame)
                    }
                default:
                    break
                }
            }

        case .sidebar:
            let panelWidth = min(320, frame.width * 0.25)
            let slideRect = CGRect(x: 0, y: 0, width: frame.width - panelWidth, height: frame.height)
            let panelRect = CGRect(x: frame.width - panelWidth, y: 0, width: panelWidth, height: frame.height)
            if let slideImage {
                canvas = aspectFit(slideImage, in: slideRect).composited(over: canvas)
            }
            let panel = CIImage(color: CIColor(red: 0.09, green: 0.09, blue: 0.11)).cropped(to: panelRect)
            canvas = panel.composited(over: canvas)
            if let cameraImage {
                canvas = aspectFill(cameraImage, in: panelRect).composited(over: canvas)
            }
        }

        canvas = canvas.cropped(to: frame)
        guard let buffer = dequeueBuffer(size: canvasSize) else { return nil }
        ciContext.render(canvas, to: buffer, bounds: frame, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (buffer, canvas)
    }

    func makeCGImage(_ image: CIImage) -> CGImage? {
        ciContext.createCGImage(image, from: image.extent)
    }

    /// Mean per-channel difference between two slide frames, 0…1. Used for
    /// slide-change (chapter) detection.
    func slideChangeScore(current: CVPixelBuffer, previous: CVPixelBuffer) -> Double {
        let a = CIImage(cvPixelBuffer: current)
        let b = CIImage(cvPixelBuffer: previous)
        guard a.extent == b.extent else { return 1 }
        let diff = a.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: b])
        let average = CIFilter.areaAverage()
        average.inputImage = diff
        average.extent = a.extent
        guard let output = average.outputImage else { return 0 }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
    }

    // MARK: - Person segmentation

    /// Runs Vision person segmentation on alternating frames (the cached mask
    /// is reused in between to halve the inference cost at 30 fps).
    private func personMask(for buffer: CVPixelBuffer, mirrored: Bool) -> CIImage? {
        segmentationTick += 1
        if segmentationTick % 2 == 0, let lastMask {
            return lastMask
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        try? handler.perform([segmentationRequest])
        guard let maskBuffer = segmentationRequest.results?.first?.pixelBuffer else {
            return lastMask
        }
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        if mirrored {
            mask = mask.oriented(.upMirrored)
        }
        let cameraExtent = CIImage(cvPixelBuffer: buffer).extent
        let scaleX = cameraExtent.width / mask.extent.width
        let scaleY = cameraExtent.height / mask.extent.height
        mask = mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        lastMask = mask
        return mask
    }

    // MARK: - Layout helpers

    /// Scale to fit entirely inside `rect`, centered (letterboxed on black).
    private func aspectFit(_ image: CIImage, in rect: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = min(rect.width / extent.width, rect.height / extent.height)
        var result = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = rect.minX + (rect.width - result.extent.width) / 2 - result.extent.minX
        let dy = rect.minY + (rect.height - result.extent.height) / 2 - result.extent.minY
        result = result.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        return result
    }

    /// Scale to fill `rect` completely, center-cropping the overflow.
    private func aspectFill(_ image: CIImage, in rect: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = max(rect.width / extent.width, rect.height / extent.height)
        var result = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(
            x: result.extent.midX - rect.width / 2,
            y: result.extent.midY - rect.height / 2,
            width: rect.width,
            height: rect.height
        )
        result = result.cropped(to: crop)
        return result.transformed(by: CGAffineTransform(translationX: rect.minX - crop.minX, y: rect.minY - crop.minY))
    }

    /// Camera PiP with a white border and rounded (or circular) mask.
    private func pip(_ camera: CIImage, in rect: CGRect, cornerRadius: CGFloat, on canvas: CIImage, frame: CGRect) -> CIImage {
        let borderWidth: CGFloat = 3
        let border = roundedRect(rect.insetBy(dx: -borderWidth, dy: -borderWidth), radius: cornerRadius + borderWidth, color: .white)
        let withBorder = border.composited(over: canvas)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = aspectFill(camera, in: rect)
        blend.backgroundImage = withBorder
        blend.maskImage = roundedRect(rect, radius: cornerRadius, color: .white)
        let result = blend.outputImage ?? withBorder
        return result.cropped(to: frame)
    }

    private func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let generator = CIFilter.roundedRectangleGenerator()
        generator.extent = rect
        generator.radius = Float(radius)
        generator.color = color
        return generator.outputImage?.cropped(to: rect) ?? CIImage.empty()
    }

    // MARK: - Pixel buffers

    private func dequeueBuffer(size: CGSize) -> CVPixelBuffer? {
        let key = "\(Int(size.width))x\(Int(size.height))"
        if pools[key] == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool)
            pools[key] = newPool
        }
        guard let pool = pools[key] else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }
}
