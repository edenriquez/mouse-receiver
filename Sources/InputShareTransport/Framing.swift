import Foundation

public enum Framing {
    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        data.append(payload)
        return data
    }

    public static func deframe(buffer: inout Data) -> [Data] {
        var frames: [Data] = []
        while buffer.count >= 4 {
            let lengthData = buffer.prefix(4)
            let length = lengthData.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(as: UInt32.self)
            }.bigEndian
            let total = 4 + Int(length)
            guard buffer.count >= total else { break }
            let payload = buffer.subdata(in: 4..<total)
            frames.append(payload)
            buffer.removeSubrange(0..<total)
        }
        return frames
    }
}
