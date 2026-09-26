import Foundation
import COnnxRuntime

public enum ORTError: Error, CustomStringConvertible {
    case api(String)
    case missingOutput(String)
    case badShape(String)

    public var description: String {
        switch self {
        case .api(let m): return "onnxruntime: \(m)"
        case .missingOutput(let n): return "onnxruntime: model produced no output named '\(n)'"
        case .badShape(let m): return "onnxruntime: \(m)"
        }
    }
}

/// Process-wide handle to the ONNX Runtime C API function table.
final class ORTRuntime {
    static let shared = ORTRuntime()

    let api: OrtApi
    let env: OpaquePointer
    let allocator: UnsafeMutablePointer<OrtAllocator>

    private init() {
        guard let base = OrtGetApiBase()?.pointee.GetApi,
              let table = base(UInt32(ORT_API_VERSION))?.pointee else {
            fatalError("could not load the ONNX Runtime C API (version \(ORT_API_VERSION))")
        }
        api = table

        var env: OpaquePointer?
        _ = api.CreateEnv(ORT_LOGGING_LEVEL_ERROR, "OpenWhisperFlow", &env)
        guard let env else { fatalError("could not create an ONNX Runtime environment") }
        self.env = env

        var allocator: UnsafeMutablePointer<OrtAllocator>?
        _ = api.GetAllocatorWithDefaultOptions(&allocator)
        guard let allocator else { fatalError("could not obtain the ONNX Runtime allocator") }
        self.allocator = allocator
    }

    @discardableResult
    func check(_ status: OpaquePointer?) throws -> Bool {
        guard let status else { return true }
        let message = api.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown error"
        api.ReleaseStatus(status)
        throw ORTError.api(message)
    }
}

/// A tensor owned by ONNX Runtime.
///
/// Values that come back from `Session.run` are kept as opaque handles so they
/// can be fed straight back in as inputs on the next call. That matters for
/// autoregressive decoding: the key/value cache is tens of megabytes per step
/// and never needs to cross into Swift memory.
public final class ORTTensor {
    let value: OpaquePointer
    private let owned: Bool

    init(value: OpaquePointer, owned: Bool = true) {
        self.value = value
        self.owned = owned
    }

    deinit {
        if owned { ORTRuntime.shared.api.ReleaseValue(value) }
    }

    private static func make(shape: [Int64], type: ONNXTensorElementDataType) throws -> OpaquePointer {
        let rt = ORTRuntime.shared
        var value: OpaquePointer?
        var shape = shape
        try rt.check(rt.api.CreateTensorAsOrtValue(rt.allocator, &shape, shape.count, type, &value))
        guard let value else { throw ORTError.api("CreateTensorAsOrtValue returned no value") }
        return value
    }

    private static func data<T>(_ value: OpaquePointer, as _: T.Type) throws -> UnsafeMutablePointer<T> {
        let rt = ORTRuntime.shared
        var raw: UnsafeMutableRawPointer?
        try rt.check(rt.api.GetTensorMutableData(value, &raw))
        guard let raw else { throw ORTError.api("GetTensorMutableData returned no buffer") }
        return raw.bindMemory(to: T.self, capacity: 1)
    }

    /// Creates a float tensor, letting `fill` write the elements in place.
    public static func float(shape: [Int64], fill: (UnsafeMutableBufferPointer<Float>) -> Void) throws -> ORTTensor {
        let count = Int(shape.reduce(1, *))
        let value = try make(shape: shape, type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
        // An empty tensor (a zero-length cache, say) has no backing buffer and
        // ONNX Runtime hands back a null pointer for it, which is not an error.
        if count > 0 {
            let ptr = try data(value, as: Float.self)
            fill(UnsafeMutableBufferPointer(start: ptr, count: count))
        }
        return ORTTensor(value: value)
    }

    /// Creates an all-zero float tensor. Used for the empty first-step caches.
    public static func zeros(shape: [Int64]) throws -> ORTTensor {
        try float(shape: shape) { buffer in
            buffer.initialize(repeating: 0)
        }
    }

    public static func int64(shape: [Int64], values: [Int64]) throws -> ORTTensor {
        let value = try make(shape: shape, type: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64)
        let ptr = try data(value, as: Int64.self)
        for (i, v) in values.enumerated() { ptr[i] = v }
        return ORTTensor(value: value)
    }

    /// Moonshine's merged decoder selects its cache branch with a Bool tensor.
    public static func bool(_ flag: Bool) throws -> ORTTensor {
        let value = try make(shape: [1], type: ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL)
        let ptr = try data(value, as: Bool.self)
        ptr[0] = flag
        return ORTTensor(value: value)
    }

    public var shape: [Int64] {
        let rt = ORTRuntime.shared
        var info: OpaquePointer?
        guard rt.api.GetTensorTypeAndShape(value, &info) == nil, let info else { return [] }
        defer { rt.api.ReleaseTensorTypeAndShapeInfo(info) }
        var rank = 0
        guard rt.api.GetDimensionsCount(info, &rank) == nil else { return [] }
        var dims = [Int64](repeating: 0, count: rank)
        guard rt.api.GetDimensions(info, &dims, rank) == nil else { return [] }
        return dims
    }

    public var elementCount: Int { Int(shape.reduce(1, *)) }

    /// Reads the tensor's float elements. The pointer is valid while the tensor is.
    public func withFloats<R>(_ body: (UnsafeBufferPointer<Float>) throws -> R) throws -> R {
        let count = elementCount
        guard count > 0 else { return try body(UnsafeBufferPointer(start: nil, count: 0)) }
        let ptr = try Self.data(value, as: Float.self)
        return try body(UnsafeBufferPointer(start: ptr, count: count))
    }
}

/// A loaded ONNX model.
public final class ORTSession {
    private let session: OpaquePointer
    private let options: OpaquePointer
    public let inputNames: [String]
    public let outputNames: [String]
    private var cNames: [String: UnsafeMutablePointer<CChar>] = [:]

    public init(modelPath: String, threads: Int = 0) throws {
        let rt = ORTRuntime.shared

        var options: OpaquePointer?
        try rt.check(rt.api.CreateSessionOptions(&options))
        guard let options else { throw ORTError.api("CreateSessionOptions returned no value") }
        self.options = options

        try rt.check(rt.api.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))
        let threadCount = threads > 0 ? threads : max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        try rt.check(rt.api.SetIntraOpNumThreads(options, Int32(threadCount)))
        try rt.check(rt.api.SetInterOpNumThreads(options, 1))

        var session: OpaquePointer?
        try rt.check(rt.api.CreateSession(rt.env, modelPath, options, &session))
        guard let session else { throw ORTError.api("CreateSession returned no value") }
        self.session = session

        func names(count: (OpaquePointer, UnsafeMutablePointer<Int>) -> OpaquePointer?,
                   name: (OpaquePointer, Int, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> OpaquePointer?) throws -> [String] {
            var n = 0
            try rt.check(count(session, &n))
            return try (0..<n).map { index in
                var raw: UnsafeMutablePointer<CChar>?
                try rt.check(name(session, index, &raw))
                guard let raw else { return "" }
                defer { _ = rt.api.AllocatorFree(rt.allocator, raw) }
                return String(cString: raw)
            }
        }

        inputNames = try names(
            count: { rt.api.SessionGetInputCount($0, $1) },
            name: { rt.api.SessionGetInputName($0, $1, rt.allocator, $2) })
        outputNames = try names(
            count: { rt.api.SessionGetOutputCount($0, $1) },
            name: { rt.api.SessionGetOutputName($0, $1, rt.allocator, $2) })

        for name in inputNames + outputNames where cNames[name] == nil {
            cNames[name] = strdup(name)
        }
    }

    deinit {
        let rt = ORTRuntime.shared
        rt.api.ReleaseSession(session)
        rt.api.ReleaseSessionOptions(options)
        for (_, p) in cNames { free(p) }
    }

    /// The declared shape of an input. Dynamic dimensions come back as -1,
    /// static ones as their real size — which is how the decoder's attention
    /// geometry (head count, head dimension) is discovered at load time instead
    /// of being hardcoded per model variant.
    public func inputShape(_ name: String) throws -> [Int64] {
        guard let index = inputNames.firstIndex(of: name) else { return [] }
        let rt = ORTRuntime.shared
        var typeInfo: OpaquePointer?
        try rt.check(rt.api.SessionGetInputTypeInfo(session, index, &typeInfo))
        guard let typeInfo else { return [] }
        defer { rt.api.ReleaseTypeInfo(typeInfo) }

        var tensorInfo: OpaquePointer?
        try rt.check(rt.api.CastTypeInfoToTensorInfo(typeInfo, &tensorInfo))
        guard let tensorInfo else { return [] }

        var rank = 0
        try rt.check(rt.api.GetDimensionsCount(tensorInfo, &rank))
        var dims = [Int64](repeating: 0, count: rank)
        try rt.check(rt.api.GetDimensions(tensorInfo, &dims, rank))
        return dims
    }

    private func cName(_ name: String) -> UnsafeMutablePointer<CChar> {
        if let existing = cNames[name] { return existing }
        let made = strdup(name)!
        cNames[name] = made
        return made
    }

    /// Runs the model. Returned tensors are owned by the caller.
    public func run(inputs: [(name: String, tensor: ORTTensor)], outputs requested: [String]) throws -> [String: ORTTensor] {
        let rt = ORTRuntime.shared
        var inNames: [UnsafePointer<CChar>?] = inputs.map { UnsafePointer(cName($0.name)) }
        var inValues: [OpaquePointer?] = inputs.map { $0.tensor.value }
        var outNames: [UnsafePointer<CChar>?] = requested.map { UnsafePointer(cName($0)) }
        var outValues = [OpaquePointer?](repeating: nil, count: requested.count)

        try rt.check(rt.api.Run(session, nil,
                                &inNames, &inValues, inputs.count,
                                &outNames, requested.count, &outValues))

        var result: [String: ORTTensor] = [:]
        result.reserveCapacity(requested.count)
        for (index, name) in requested.enumerated() {
            guard let value = outValues[index] else { throw ORTError.missingOutput(name) }
            result[name] = ORTTensor(value: value)
        }
        return result
    }
}
