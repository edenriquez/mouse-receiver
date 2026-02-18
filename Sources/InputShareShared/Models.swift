import Foundation

public enum InputShareInjectionMarker {
    public static let value: Int64 = 0x4950534852414552
}

public enum InputShareMessageType: String, Codable, Sendable {
    case hello
    case inputEvent
    case activate
    case activated
    case deactivate
    case deactivated
    case pairRequest
    case pairAccept
}

public struct MessageEnvelope: Codable, Sendable {
    public var protocolVersion: Int
    public var messageType: InputShareMessageType
    public var sequenceNumber: UInt64
    public var monotonicTimeNs: UInt64
    public var sourceDeviceId: String
    public var payload: Data

    public init(
        protocolVersion: Int,
        messageType: InputShareMessageType,
        sequenceNumber: UInt64,
        monotonicTimeNs: UInt64,
        sourceDeviceId: String,
        payload: Data
    ) {
        self.protocolVersion = protocolVersion
        self.messageType = messageType
        self.sequenceNumber = sequenceNumber
        self.monotonicTimeNs = monotonicTimeNs
        self.sourceDeviceId = sourceDeviceId
        self.payload = payload
    }
}

public enum MouseButton: String, Codable, Sendable {
    case left
    case right
    case other
}

public enum ButtonState: String, Codable, Sendable {
    case down
    case up
}

public struct NormalizedPoint: Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ScrollDelta: Codable, Sendable {
    public var deltaX: Double
    public var deltaY: Double

    public init(deltaX: Double, deltaY: Double) {
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}

public struct InputEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case mouseMove
        case mouseButton
        case scroll
        case key
        case flagsChanged
    }

    public var kind: Kind
    public var normalizedPosition: NormalizedPoint?
    public var button: MouseButton?
    public var buttonState: ButtonState?
    public var scroll: ScrollDelta?
    public var keyCode: UInt16?
    public var keyState: ButtonState?
    public var flags: UInt64

    public init(
        kind: Kind,
        normalizedPosition: NormalizedPoint? = nil,
        button: MouseButton? = nil,
        buttonState: ButtonState? = nil,
        scroll: ScrollDelta? = nil,
        keyCode: UInt16? = nil,
        keyState: ButtonState? = nil,
        flags: UInt64
    ) {
        self.kind = kind
        self.normalizedPosition = normalizedPosition
        self.button = button
        self.buttonState = buttonState
        self.scroll = scroll
        self.keyCode = keyCode
        self.keyState = keyState
        self.flags = flags
    }
}

public struct ActivatePayload: Codable, Sendable {
    public var normalizedPosition: NormalizedPoint

    public init(normalizedPosition: NormalizedPoint) {
        self.normalizedPosition = normalizedPosition
    }
}

public struct PairRequestPayload: Codable, Sendable {
    public var deviceName: String
    public var deviceId: String

    public init(deviceName: String, deviceId: String) {
        self.deviceName = deviceName
        self.deviceId = deviceId
    }
}

public struct PairAcceptPayload: Codable, Sendable {
    public var deviceName: String
    public var deviceId: String

    public init(deviceName: String, deviceId: String) {
        self.deviceName = deviceName
        self.deviceId = deviceId
    }
}

public enum InputShareCodec {
    public static let protocolVersion = 1

    public static func encodeEnvelope(_ envelope: MessageEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    public static func decodeEnvelope(_ data: Data) throws -> MessageEnvelope {
        try JSONDecoder().decode(MessageEnvelope.self, from: data)
    }

    public static func encodePayload<T: Encodable>(_ payload: T) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    public static func decodePayload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

public enum MonotonicClock {
    public static func nowNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}
