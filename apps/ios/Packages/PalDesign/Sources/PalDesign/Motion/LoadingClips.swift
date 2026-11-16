import Foundation

struct LoadingClip: Sendable {
    enum Motion: Sendable {
        case keyframes(KeyframeTrack)
        case procedural(@Sendable (Double) -> AvatarPose)
    }

    let name: String
    let duration: Double
    let motion: Motion

    init(name: String, track: KeyframeTrack) {
        self.name = name
        duration = track.duration
        motion = .keyframes(track)
    }

    init(name: String, duration: Double, pose: @escaping @Sendable (Double) -> AvatarPose) {
        self.name = name
        self.duration = duration
        motion = .procedural(pose)
    }

    var keys: [Keyframe] {
        if case .keyframes(let track) = motion { track.keys } else { [] }
    }

    func pose(at t: Double) -> AvatarPose {
        switch motion {
        case .keyframes(let track): track.pose(at: t)
        case .procedural(let pose): pose(min(max(t, 0), duration))
        }
    }
}

enum LoadingClips {
    static let resourceName = "avatar-loading-clips"

    static let all: [LoadingClip] = parse(bundledData())
    static let eyesOnly: Set<String> = ["squint", "dot-stare"]
    static let played: [LoadingClip] = all.filter { !eyesOnly.contains($0.name) }

    static let cycleDuration: Double = played.reduce(0) { $0 + $1.duration }

    static func bundledData() -> Data {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "json") else {
            preconditionFailure("\(resourceName).json is missing from the PalDesign bundle")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            preconditionFailure("\(resourceName).json is unreadable: \(error)")
        }
    }

    static func parse(_ data: Data) -> [LoadingClip] {
        let file: ClipFile
        do {
            file = try JSONDecoder().decode(ClipFile.self, from: data)
        } catch {
            preconditionFailure("\(resourceName).json is malformed: \(error)")
        }
        precondition(file.version == 1, "\(resourceName).json has an unsupported version \(file.version)")
        precondition(!file.clips.isEmpty, "\(resourceName).json has no clips")
        return file.clips.map { clip in
            precondition(clip.keys.first?.t == 0, "clip \(clip.name) must start at t=0")
            return LoadingClip(name: clip.name, track: KeyframeTrack(clip.keys.map { key in
                Keyframe(time: key.t, pose: pose(key.pose, clip: clip.name), ease: key.ease)
            }))
        }
    }

    private static func pose(_ fields: [String: Double], clip: String) -> AvatarPose {
        var pose = AvatarPose.facing
        for (name, value) in fields {
            guard let path = AvatarPose.named[name] else {
                preconditionFailure("clip \(clip) sets unknown pose field \(name)")
            }
            pose[keyPath: path] = value
        }
        return pose
    }

    private struct ClipFile: Decodable {
        let version: Int
        let clips: [ClipRecord]
    }

    private struct ClipRecord: Decodable {
        let name: String
        let keys: [KeyRecord]
    }

    private struct KeyRecord: Decodable {
        let t: Double
        let ease: Ease
        let pose: [String: Double]
    }
}
