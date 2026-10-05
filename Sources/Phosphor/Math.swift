import simd

extension simd_float4x4 {
    /// Right-handed, Metal clip space (z in 0...1).
    static func perspective(fovyRadians fovy: Float, aspect: Float, near: Float, far: Float) -> Self {
        let y = 1 / tan(fovy * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return Self(columns: (
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)
        ))
    }

    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> Self {
        let f = normalize(center - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        return Self(columns: (
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        ))
    }
}

extension SIMD3 where Scalar == Float {
    func rotated(by q: simd_quatf) -> Self { q.act(self) }
}

func hsv(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
    let k = SIMD3<Float>(5, 3, 1)
    let x = k + SIMD3(repeating: h * 6)
    let p = x - 6 * floor(x / 6)
    let t = simd_clamp(simd_min(p, 4 - p), SIMD3(repeating: 0), SIMD3(repeating: 1))
    return v - v * s * t
}

/// Deterministic randomness from a string (e.g. a fingerprint).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    init(string: String) {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a
        for b in string.utf8 {
            h ^= UInt64(b)
            h &*= 0x100_0000_01b3
        }
        state = h
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
