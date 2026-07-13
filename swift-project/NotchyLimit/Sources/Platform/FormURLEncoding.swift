import Foundation

extension String {
    /// Percent-encodes the receiver for safe use as a value inside an
    /// `application/x-www-form-urlencoded` request body.
    ///
    /// OAuth refresh tokens and client secrets routinely contain reserved
    /// characters — Google refresh tokens start `1//…`, and a literal `+`
    /// decodes to a space on the server. Interpolating such a value into a
    /// body unencoded silently corrupts the request (a failed refresh then
    /// looks like an expired token). Encoding to the RFC 3986 unreserved set
    /// keeps every value intact.
    var formURLEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
