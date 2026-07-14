import AppKit
import AVFoundation

/// Miniature du résultat (première seconde de la vidéo).
enum Miniature {
    static func generer(pour url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generateur = AVAssetImageGenerator(asset: asset)
        generateur.appliesPreferredTrackTransform = true
        generateur.maximumSize = CGSize(width: 640, height: 640)
        let temps = CMTime(seconds: 1, preferredTimescale: 600)
        do {
            let (image, _) = try await generateur.image(at: temps)
            return NSImage(cgImage: image, size: .zero)
        } catch {
            return nil
        }
    }
}
