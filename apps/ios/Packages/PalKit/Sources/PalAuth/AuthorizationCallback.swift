public enum AuthorizationCallback {
    public static func code(from parameters: [String: String], expectedState: String) throws -> String {
        guard let returned = parameters["state"], ConstantTime.equal(returned, expectedState) else {
            throw SignInError.stateMismatch
        }
        if let denied = parameters["error"] {
            throw SignInError.authorizationDenied(String(denied.prefix(64)))
        }
        guard let code = parameters["code"], !code.isEmpty else { throw SignInError.missingAuthorizationCode }
        return code
    }
}
