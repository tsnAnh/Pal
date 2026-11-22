import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("usage: sparkle-signature-check.swift <public-key-base64> <signature-base64> <file>")
}

let trimmed = { (value: String) in value.trimmingCharacters(in: .whitespacesAndNewlines) }

guard let keyBytes = Data(base64Encoded: trimmed(arguments[1])),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
else {
    fail("public key is not a base64 Ed25519 key")
}
guard let signature = Data(base64Encoded: trimmed(arguments[2])) else {
    fail("signature is not base64")
}
guard let payload = FileManager.default.contents(atPath: arguments[3]) else {
    fail("cannot read \(arguments[3])")
}
guard publicKey.isValidSignature(signature, for: payload) else {
    fail("signature does not verify against the public key")
}
print("signature verified")
