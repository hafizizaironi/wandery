import UIKit
import Vision

/// On-device classifier that decides whether a freshly-published post is
/// safe + interesting enough to surface in the public Discover feed.
///
/// This is CafeHunter's implicit-consent mechanism: instead of asking
/// every poster "do you want this in Discover?", we ask Apple's Vision
/// models two questions:
///
///   1. Are there any human faces in the photo? (privacy gate)
///   2. Does Apple's aesthetic-scoring model rate it well? (quality gate)
///
/// If both gates pass, the post becomes `discoverable: true` and may show
/// up to strangers exploring the place. If either fails, the post stays
/// inside the author's friend graph — same as everything else today.
///
/// Runs entirely on-device (Neural Engine) — no network round-trip, no
/// API cost, and the photo bytes never leave the user's phone for this
/// classification step.
///
/// Threat note: a malicious client could lie about the verdict before
/// writing to Firestore. We accept that risk for v1 — the manual "Hide
/// from Discover" toggle gives users an escape hatch, and we can add
/// server-side re-verification later if abuse appears in practice.
enum PostClassifier {
    /// Result of classifying one image. Stamped onto the post doc so
    /// future Discover queries can filter without re-running Vision.
    struct Verdict: Sendable, Equatable {
        let containsFaces: Bool
        let aestheticScore: Double
        let discoverable: Bool
    }

    /// Aesthetic-score floor a post must clear to be considered for
    /// Discover. Apple's score is 0…1; 0.6 sits comfortably in the
    /// "well-composed shot of a place" zone in informal testing. Tune
    /// based on real CafeHunter content before launch.
    static let aestheticFloor: Double = 0.6

    /// Classify a UIImage. Runs face detection + aesthetic scoring in
    /// parallel — both are cheap (each <150ms on modern A-series silicon).
    /// Returns a Verdict whose `discoverable` flag is the conjunction of
    /// the privacy gate and the quality gate.
    ///
    /// Returns a "safe" Verdict (discoverable=false, containsFaces=true)
    /// if either request fails — defaulting to private is the only right
    /// posture under uncertainty.
    static func classify(_ image: UIImage) async -> Verdict {
        guard let cgImage = image.cgImage else {
            return Verdict(containsFaces: true, aestheticScore: 0, discoverable: false)
        }
        async let faces = detectFaces(cgImage: cgImage)
        async let aesthetic = aestheticScore(cgImage: cgImage)
        let (faceCount, score) = await (faces, aesthetic)
        let containsFaces = faceCount > 0
        let discoverable = !containsFaces && score >= aestheticFloor
        return Verdict(
            containsFaces: containsFaces,
            aestheticScore: score,
            discoverable: discoverable
        )
    }

    // MARK: - Face detection

    private static func detectFaces(cgImage: CGImage) async -> Int {
        await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
            let request = VNDetectFaceRectanglesRequest { req, _ in
                let count = (req.results as? [VNFaceObservation])?.count ?? 0
                cont.resume(returning: count)
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                // On error, assume the worst — treat as containing faces so
                // the post stays out of Discover. False-negative-safe.
                #if DEBUG
                print("[PostClassifier] face detection failed: \(error.localizedDescription)")
                #endif
                cont.resume(returning: Int.max)
            }
        }
    }

    // MARK: - Aesthetic score

    /// Apple's aesthetic scorer (iOS 18+). Returns 0…1; higher = more
    /// aesthetically pleasing per Apple's pretrained model. Same model
    /// powers Photos.app's "Featured Photos".
    private static func aestheticScore(cgImage: CGImage) async -> Double {
        await withCheckedContinuation { (cont: CheckedContinuation<Double, Never>) in
            let request = CalculateImageAestheticsScoresRequest()
            Task {
                do {
                    let observation = try await request.perform(on: cgImage)
                    cont.resume(returning: Double(observation.overallScore))
                } catch {
                    #if DEBUG
                    print("[PostClassifier] aesthetic score failed: \(error.localizedDescription)")
                    #endif
                    cont.resume(returning: 0)
                }
            }
        }
    }
}
