import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads QR codes from images with the system Vision framework: no camera, no screen-recording
/// permission, nothing leaves the Mac. Used to import the "scan this code" secret that sites show
/// when two-factor login is turned on.
public enum QRCode {
    /// Payload strings of every QR code found in the image.
    public static func decode(_ image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }

    /// From file bytes (PNG, JPEG, HEIC, TIFF…).
    public static func decode(data: Data) -> [String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        return decode(image)
    }
}
