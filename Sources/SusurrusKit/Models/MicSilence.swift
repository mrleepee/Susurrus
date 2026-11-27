import Foundation

/// Spotting a microphone that delivers digital silence. A working mic always
/// picks up some room noise (around -60 dBFS even in a quiet room), so audio
/// that stays below -80 dBFS for a second and a half means nothing is getting
/// through: a stuck macOS audio service, a muted or disconnected input, or a
/// revoked permission. Seen 2026-11-27: every dictation came back blank with
/// peak 0.000 until `coreaudiod` was restarted.
public enum MicSilence {
    /// -80 dBFS. Far below any real room's noise floor.
    public static let deadPeak: Float = 0.0001

    /// How much audio must be dead before the panel says so.
    public static let window: Double = 1.5

    public static func isDead(peak: Float) -> Bool { peak < deadPeak }

    public static func peak<C: Collection>(of samples: C) -> Float where C.Element == Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }
}
