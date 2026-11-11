#if os(macOS)
import Foundation

enum PosixError {
    static func map(_ code: Int32, path: String, action: String) -> DeviceProviderError {
        switch code {
        case ENOENT, ENOTDIR: .notFound
        case EACCES, EPERM: .accessDenied(path)
        case EISDIR: .invalidArgs("\(path) is a directory.")
        case ENOSPC: .failed("The disk is full, so \(path) could not be written.")
        default: .failed("Could not \(action) \(path): \(String(cString: strerror(code))).")
        }
    }

    static func map(_ error: any Error, path: String, action: String) -> DeviceProviderError {
        if let known = error as? DeviceProviderError { return known }
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return map(Int32(underlying.code), path: path, action: action)
        }
        if nsError.domain == NSPOSIXErrorDomain { return map(Int32(nsError.code), path: path, action: action) }
        switch nsError.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .notFound
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return .accessDenied(path)
        default: return .failed("Could not \(action) \(path).")
        }
    }
}
#endif
