import Algorithms // for Collection.trim

/// A String which is known to contain a valid URL.
///
public struct XURL {
    var string: String
}

extension XURL {
    public enum Scheme: RawRepresentable, Equatable, Hashable, Codable {
        case ftp
        case file
        case http
        case https
        case ws
        case wss
        case other(String)
        
        public init(rawValue: String) {
            switch rawValue {
            case "ftp":   self = .ftp
            case "file":  self = .file
            case "http":  self = .http
            case "https": self = .https
            case "ws":    self = .ws
            case "wss":   self = .wss
            default:      self = .other(rawValue)
            }
        }
        public var rawValue: String {
            switch self {
            case .ftp: return "ftp"
            case .file: return "file"
            case .http: return "http"
            case .https: return "https"
            case .ws: return "ws"
            case .wss: return "wss"
            case .other(let scheme): return scheme
            }
        }
        
        static func parse<C>(asciiBytes: C) -> Scheme where C: Collection, C.Element == UInt8 {
            func notRecognised() -> Scheme {
                // FIXME (swift): This should be `Unicode.ASCII.self`, but UTF8 decoding is literally 10x faster.
                return .other(String(decoding: asciiBytes, as: UTF8.self))
            }
            // We use ASCII.init(_unchecked:) because we're only checking equality for specific ASCII sequences.
            // We don't actually care if the byte is ASCII, or use any algorithms which rely on that.
            var iter = asciiBytes.lazy.map { ASCII(_unchecked: $0) }.makeIterator()
            switch iter.next() {
            case .h?:
                guard iter.next() == .t, iter.next() == .t, iter.next() == .p else { return notRecognised() }
                switch iter.next() {
                case .s?:
                    guard iter.next() == nil else { return notRecognised() }
                    return .https
                case .none:
                    return .http
                case .some(_):
                    return notRecognised()
                }
            case .f?:
                switch iter.next() {
                case .i?:
                    guard iter.next() == .l, iter.next() == .e, iter.next() == nil else { return notRecognised() }
                    return .file
                case .t?:
                    guard iter.next() == .p, iter.next() == nil else { return notRecognised() }
                    return .ftp
                default:
                    return notRecognised()
                }
            case .w?:
                guard iter.next() == .s else { return notRecognised() }
            	switch iter.next() {
                case .s?:
                    guard iter.next() == nil else { return notRecognised() }
                    return .wss
                case .none:
                    return .ws
                default:
                    return notRecognised()
                }
            default:
                return notRecognised()
            }
        }
        
        var defaultPort: UInt16? {
            switch self {
            case .ftp:   return 21
            case .file:  return nil
            case .http:  return 80
            case .https: return 443
            case .ws:    return 80
            case .wss:   return 443
            case .other: return nil
            }
        }
        
        public var isSpecial: Bool {
            if case .other = self { return false }
            return true
        }
    }
}

extension XURL {
    
    public struct Components: Equatable, Hashable, Codable {
        fileprivate final class Storage: Equatable, Hashable, Codable {
            var scheme: XURL.Scheme
            var username: String
            var password: String
            var host: XURL.Host?
            var port: UInt16?
            var path: [String]
            var query: String?
            var fragment: String?
            var cannotBeABaseURL = false
            // TODO:
            // URL also has an associated blob URL entry that is either null or a blob URL entry. It is initially null.
         
            init(scheme: Scheme, username: String, password: String, host: XURL.Host?,
                 port: UInt16?, path: [String], query: String?, fragment: String?,
                 cannotBeABaseURL: Bool) {
                self.scheme = scheme; self.username = username; self.password = password; self.host = host
                self.port = port; self.path = path; self.query = query; self.fragment = fragment
                self.cannotBeABaseURL = cannotBeABaseURL
            }
            
            func copy() -> Self {
                return Self(
                    scheme: scheme, username: username, password: password, host: host,
                    port: port, path: path, query: query, fragment: fragment,
                    cannotBeABaseURL: cannotBeABaseURL
                )
            }
            
            static func == (lhs: Storage, rhs: Storage) -> Bool {
            	return
                lhs.scheme == rhs.scheme &&
                lhs.username == rhs.username &&
                lhs.password == rhs.password &&
                lhs.host == rhs.host &&
                lhs.port == rhs.port &&
                lhs.path == rhs.path &&
                lhs.query == rhs.query &&
                lhs.fragment == rhs.fragment &&
                lhs.cannotBeABaseURL == rhs.cannotBeABaseURL
            }
            
            func hash(into hasher: inout Hasher) {
                scheme.hash(into: &hasher)
                username.hash(into: &hasher)
                password.hash(into: &hasher)
                host.hash(into: &hasher)
                port.hash(into: &hasher)
                path.hash(into: &hasher)
                query.hash(into: &hasher)
                fragment.hash(into: &hasher)
                cannotBeABaseURL.hash(into: &hasher)
            }
            
            var hasCredentials: Bool {
                !username.isEmpty || !password.isEmpty
            }
            
            /// Copies the username, password, host and port fields from `other`.
            ///
            func copyAuthority(from other: XURL.Components.Storage) {
                self.username = other.username
                self.password = other.password
                self.host     = other.host
                self.port     = other.port
            }
        }
        
        fileprivate var _storage: Storage
        
        private mutating func ensureUnique() {
            if !isKnownUniquelyReferenced(&_storage) {
                _storage = _storage.copy()
            }
        }
        
        fileprivate init(_storage: Storage) {
            self._storage = _storage
        }
        
        public init(scheme: Scheme = .other(""), username: String = "", password: String = "", host: XURL.Host? = nil,
                    port: UInt16? = nil, path: [String] = [], query: String? = nil, fragment: String? = nil,
                     cannotBeABaseURL: Bool = false) {
            self._storage = Storage(
                scheme: scheme, username: username, password: password, host: host,
                port: port, path: path, query: query, fragment: fragment,
                cannotBeABaseURL: cannotBeABaseURL
            )
        }
    }
}

extension XURL.Components {
        
    
    /// A URL’s scheme is an ASCII string that identifies the type of URL and can be used to dispatch a URL for further processing after parsing. It is initially the empty string.
    ///
    /// https://url.spec.whatwg.org/#url-representation as of 14.06.2020
    ///
    public var scheme: XURL.Scheme {
        get { return _storage.scheme }
        set { ensureUnique(); _storage.scheme = newValue }
    }
    
    /// A URL’s username is an ASCII string identifying a username. It is initially the empty string.
    ///
    /// https://url.spec.whatwg.org/#url-representation as of 14.06.2020
    ///
    public var username: String {
       get { return _storage.username }
       set { ensureUnique(); _storage.username = newValue }
   }
  
    /// A URL’s password is an ASCII string identifying a password. It is initially the empty string.
    ///
    /// https://url.spec.whatwg.org/#url-representation as of 14.06.2020
    ///
    public var password: String {
       get { return _storage.password }
       set { ensureUnique(); _storage.password = newValue }
   }
            
    /// A URL’s host is null or a host. It is initially null.
    ///
    /// A host is a domain, an IPv4 address, an IPv6 address, an opaque host, or an empty host.
    /// Typically a host serves as a network address, but it is sometimes used as opaque identifier in URLs where a network address is not necessary.
    ///
    /// https://url.spec.whatwg.org/#url-representation as of 14.06.2020
    /// https://url.spec.whatwg.org/#host-representation as of 14.06.2020
    ///
    public var host: XURL.Host? {
       get { return _storage.host }
       set { ensureUnique(); _storage.host = newValue }
    }

    /// A URL’s port is either null or a 16-bit unsigned integer that identifies a networking port. It is initially null.
    ///
    /// https://url.spec.whatwg.org/#url-representation as of 14.06.2020
    ///
    public var port: UInt16? {
       get { return _storage.port }
       set { ensureUnique(); _storage.port = newValue }
    }

    /// A URL’s path is a list of zero or more ASCII strings, usually identifying a location in hierarchical form. It is initially empty.
    ///
    /// https://url.spec.whatwg.org/#url-representation as of 14.06.2020
    ///
    public var path: [String] {
        get { return _storage.path }
        _modify { ensureUnique(); yield &_storage.path }
        set { ensureUnique(); _storage.path = newValue }
    }
    
    /// A URL’s query is either null or an ASCII string. It is initially null.
    ///
    /// https://url.spec.whatwg.org/#url-representation as of 14.06.2020
    ///
    public var query: String? {
       get { return _storage.query }
       set { ensureUnique(); _storage.query = newValue }
    }
    
    /// A URL’s fragment is either null or an ASCII string that can be used for further processing on the resource the URL’s other components identify. It is initially null.
    ///
    /// https://url.spec.whatwg.org/#url-representation as of 14.06.2020
    ///
    public var fragment: String? {
       get { return _storage.fragment }
       set { ensureUnique(); _storage.fragment = newValue }
    }
    
    /// A URL also has an associated cannot-be-a-base-URL flag. It is initially unset.
    ///
    /// https://url.spec.whatwg.org/#url-representation as of 14.06.2020
    ///
    public var cannotBeABaseURL: Bool {
       get { return _storage.cannotBeABaseURL }
       set { ensureUnique(); _storage.cannotBeABaseURL = newValue }
    }
    
    // TODO:
    // URL also has an associated blob URL entry that is either null or a blob URL entry. It is initially null.
}

// Internal helpers.

extension XURL.Components {
    
    /// Modifies URL components by parsing a given string from the desired parser state.
    ///
    @discardableResult
    internal mutating func modify<S>(_ input: S, stateOverride: XURL.Parser.State?) -> Bool where S: StringProtocol {
        ensureUnique()
        return input._withUTF8 {
            return XURL.Parser._parse($0, base: nil, url: _storage, stateOverride: stateOverride, onValidationError: { _ in })
        }
    }
    
    /// A URL cannot have a username/password/port if its host is null or the empty string, its cannot-be-a-base-URL flag is set, or its scheme is "file".
    ///
    /// https://url.spec.whatwg.org/#url-miscellaneous as seen on 14.06.2020
    ///
    var cannotHaveCredentialsOrPort: Bool {
        return host == nil || host == .empty || self.cannotBeABaseURL || scheme == .file
    }

    /// Copies the username, password, host and port fields from `other`.
    ///
    fileprivate mutating func copyAuthority(from other: Self) {
        self.username = other.username
        self.password = other.password
        self.host     = other.host
        self.port     = other.port
    }
    
    func serialised(excludeFragment: Bool = false) -> String {
        var result = ""
        result.append(self.scheme.rawValue)
        result.append(":")
        
        if let host = self.host {
            result.append("//")
            if self._storage.hasCredentials {
                result.append(self.username)
                if !self.password.isEmpty {
                    result.append(":")
                    result.append(self.password)
                }
                result.append("@")
            }
            result.append(host.description)
            if let port = self.port {
                result.append(":")
                result.append(String(port))
            }
        } else if self.scheme == .file {
            result.append("//")
        }
        
        if self.cannotBeABaseURL {
            if self.path.isEmpty == false {
                result.append(self.path[0])
            }
        } else {
            for pathComponent in self.path {
                result.append("/\(pathComponent)")
            }
        }
        
        if let query = self.query {
            result.append("?\(query)")
        }
        if let fragment = self.fragment, excludeFragment == false {
            result.append("#\(fragment)")
        }
        return result
    }
}

extension XURL.Components: CustomDebugStringConvertible {

    public var debugDescription: String {
        return """
        Scheme:\t\(scheme)
        Username:\t\(username)
        Password:\t\(password)
        Host:\t\(host?.description ?? "<nil>")
        Port:\t\(port?.description ?? "<nil>")
        Path:\t\(path)
        Query:\t\(query ?? "<nil>")
        Fragment:\t\(fragment ?? "<nil>")
        """
    }
}

extension XURL {

    /// This parser is pretty-much a direct transcription of the WHATWG spec in to Swift.
    /// See: https://url.spec.whatwg.org/#url-parsing
    ///
    public struct Parser {}
}

extension XURL.Parser {

    enum State {
        case schemeStart
        case scheme
        case noScheme
        case specialRelativeOrAuthority
        case pathOrAuthority
        case relative
        case relativeSlash
        case specialAuthoritySlashes
        case specialAuthorityIgnoreSlashes
        case authority
        case host
        case hostname
        case port
        case file
        case fileSlash
        case fileHost
        case pathStart
        case path
        case cannotBeABaseURLPath
        case query
        case fragment
    }
    
    public struct ValidationError: Equatable, CustomStringConvertible {
        private var code: UInt8
        private var hostParserError: XURL.Host.ValidationError? = nil

        // Named errors and their descriptions/examples taken from:
        // https://github.com/whatwg/url/pull/502 on 15.06.2020
        internal static var unexpectedC0ControlOrSpace:         Self { Self(code: 0) }
        internal static var unexpectedASCIITabOrNewline:        Self { Self(code: 1) }
        internal static var invalidSchemeStart:                 Self { Self(code: 2) }
        internal static var fileSchemeMissingFollowingSolidus:  Self { Self(code: 3) }
        internal static var invalidScheme:                      Self { Self(code: 4) }
        internal static var missingSchemeNonRelativeURL:        Self { Self(code: 5) }
        internal static var relativeURLMissingBeginningSolidus: Self { Self(code: 6) }
        internal static var unexpectedReverseSolidus:           Self { Self(code: 7) }
        internal static var missingSolidusBeforeAuthority:      Self { Self(code: 8) }
        internal static var unexpectedCommercialAt:             Self { Self(code: 9) }
        internal static var missingCredentials:                 Self { Self(code: 10) }
        internal static var unexpectedPortWithoutHost:          Self { Self(code: 11) }
        internal static var emptyHostSpecialScheme:             Self { Self(code: 12) }
        internal static var hostInvalid:                        Self { Self(code: 13) }
        internal static var portOutOfRange:                     Self { Self(code: 14) }
        internal static var portInvalid:                        Self { Self(code: 15) }
        internal static var unexpectedWindowsDriveLetter:       Self { Self(code: 16) }
        internal static var unexpectedWindowsDriveLetterHost:   Self { Self(code: 17) }
        internal static var unexpectedHostFileScheme:           Self { Self(code: 18) }
        internal static var unexpectedEmptyPath:                Self { Self(code: 19) }
        internal static var invalidURLCodePoint:                Self { Self(code: 20) }
        internal static var unescapedPercentSign:               Self { Self(code: 21) }
        
        internal static func hostParserError(_ err: XURL.Host.ValidationError) -> Self {
            Self(code: 22, hostParserError: err)
        }
        // TODO: host-related errors. Map these to our existing host-parser errors.
        internal static var unclosedIPv6Address:                Self { Self(code: 22) }
        internal static var domainToASCIIFailure:               Self { Self(code: 23) }
        internal static var domainToASCIIEmptyDomainFailure:    Self { Self(code: 24) }
        internal static var hostForbiddenCodePoint:             Self { Self(code: 25) }
        // This one is not in the spec.
        internal static var _baseURLRequired:                   Self { Self(code: 99) }
        internal static var _invalidUTF8:                       Self { Self(code: 98) }
        
        public var description: String {
            switch self {
            case .unexpectedC0ControlOrSpace:
                return #"""
                The input to the URL parser contains a leading or trailing C0 control or space.
                The URL parser subsequently strips any matching code points.
                
                Example: " https://example.org "
                """#
            case .unexpectedASCIITabOrNewline:
                return #"""
                The input to the URL parser contains ASCII tab or newlines.
                The URL parser subsequently strips any matching code points.
                
                Example: "ht
                tps://example.org"
                """#
            case .invalidSchemeStart:
                return #"""
                The first code point of a URL’s scheme is not an ASCII alpha.

                Example: "3ttps://example.org"
                """#
            case .fileSchemeMissingFollowingSolidus:
                return #"""
                The URL parser encounters a URL with a "file" scheme that is not followed by "//".

                Example: "file:c:/my-secret-folder"
                """#
            case .invalidScheme:
                return #"""
                The URL’s scheme contains an invalid code point.

                Example: "^_^://example.org" and "https//example.org"
                """#
            case .missingSchemeNonRelativeURL:
                return #"""
                The input is missing a scheme, because it does not begin with an ASCII alpha,
                and either no base URL was provided or the base URL cannot be used as a base URL
                because its cannot-be-a-base-URL flag is set.

                Example (Input’s scheme is missing and no base URL is given):
                (url, base) = ("💩", nil)
                
                Example (Input’s scheme is missing, but the base URL’s cannot-be-a-base-URL flag is set):
                (url, base) = ("💩", "mailto:user@example.org")
                """#
            case .relativeURLMissingBeginningSolidus:
                return #"""
                The input is a relative-URL String that does not begin with U+002F (/).

                Example: (url, base) = ("foo.html", "https://example.org/")
                """#
            case .unexpectedReverseSolidus:
                return #"""
                The URL has a special scheme and it uses U+005C (\) instead of U+002F (/).

                Example: "https://example.org\path\to\file"
                """#
            case .missingSolidusBeforeAuthority:
                return #"""
                The URL includes credentials that are not preceded by "//".

                Example: "https:user@example.org"
                """#
            case .unexpectedCommercialAt:
                return #"""
                The URL includes credentials, however this is considered invalid.

                Example: "https://user@example.org"
                """#
            case .missingCredentials:
                return #"""
                A U+0040 (@) is found between the URL’s scheme and host, but the URL does not include credentials.

                Example: "https://@example.org"
                """#
            case .unexpectedPortWithoutHost:
                return #"""
                The URL contains a port, but no host.

                Example: "https://:443"
                """#
            case .emptyHostSpecialScheme:
                return #"""
                The URL has a special scheme, but does not contain a host.

                Example: "https://#fragment"
                """#
            case .hostInvalid:
                // FIXME: Javascript example.
                return #"""
                The host portion of the URL is an empty string when it includes credentials or a port and the basic URL parser’s state is overridden.

                Example:
                  const url = new URL("https://example:9000");
                  url.hostname = "";
                """#
            case .portOutOfRange:
                return #"""
                The input’s port is too big.

                Example: "https://example.org:70000"
                """#
            case .portInvalid:
                return #"""
                The input’s port is invalid.

                Example: "https://example.org:7z"
                """#
            case .unexpectedWindowsDriveLetter:
                return #"""
                The input is a relative-URL string that starts with a Windows drive letter and the base URL’s scheme is "file".

                Example: (url, base) = ("/c:/path/to/file", "file:///c:/")
                """#
            case .unexpectedWindowsDriveLetterHost:
                return #"""
                The file URL’s host is a Windows drive letter.

                Example: "file://c:"
                """#
            case .unexpectedHostFileScheme:
                // FIXME: Javascript example.
                return #"""
                The URL’s scheme is changed to "file" and the existing URL has a host.

                Example:
                  const url = new URL("https://example.org");
                  url.protocol = "file";
                """#
            case .unexpectedEmptyPath:
                return #"""
                The URL’s scheme is "file" and it contains an empty path segment.

                Example: "file:///c:/path//to/file"
                """#
            case .invalidURLCodePoint:
                return #"""
                A code point is found that is not a URL code point or U+0025 (%), in the URL’s path, query, or fragment.

                Example: "https://example.org/>"
                """#
            case .unescapedPercentSign:
                return #"""
                A U+0025 (%) is found that is not followed by two ASCII hex digits, in the URL’s path, query, or fragment.

                Example: "https://example.org/%s"
                """#
            case ._baseURLRequired:
                return #"""
                A base URL is required.
                """#
            case _ where self.code == Self.hostParserError(.ipv6AddressError(.emptyInput)).code:
                return self.hostParserError!.description
            default:
                return "??"
            }
        }
    }
    
    // Parse, ignoring non-fatal validation errors.

    public static func parse<S>(_ input: S, base: String? = nil) -> XURL.Components? where S: StringProtocol {
        if let baseString = base, baseString.isEmpty == false {
            return parse(baseString, baseURL: nil).flatMap { parse(input[...], baseURL: $0) }
        }
        return parse(input[...], baseURL: nil)
    }

    public static func parse<S>(_ input: S, baseURL: XURL.Components?) -> XURL.Components? where S: StringProtocol {
        return input._withUTF8 {
            let result = XURL.Components()
            return _parse($0, base: baseURL, url: result._storage, stateOverride: nil, onValidationError: { _ in }) ? result : nil
        }
    }
    
    // Parse, reporting validation errors.
    
    public struct Result {
        public var components: XURL.Components?
        public var validationErrors: [ValidationError]
    }
    
    public static func parseAndReport<S>(_ input: S, base: String? = nil) -> (url: Result?, base: Result?) where S: StringProtocol {
        if let baseString = base, baseString.isEmpty == false {
            let baseResult = parseAndReport(baseString, baseURL: nil)
            return baseResult.components.map { (parseAndReport(input, baseURL: $0), baseResult) } ?? (nil, baseResult)
        }
        return (parseAndReport(input, baseURL: nil), nil)
    }
    
    public static func parseAndReport<S>(_ input: S, baseURL: XURL.Components?) -> Result where S: StringProtocol {
        return input._withUTF8 { utf8 in
            var errors: [ValidationError] = []
            errors.reserveCapacity(8)
            let components = XURL.Components()
            if _parse(utf8, base: baseURL, url: components._storage, stateOverride: nil, onValidationError: { errors.append($0) }) {
                return Result(components: components, validationErrors: errors)
            } else {
                return Result(components: nil, validationErrors: errors)
            }
        }
    }
}

// Parsing algorithm.

extension XURL.Parser {

    /// The "Basic URL Parser" algorithm described by:
    /// https://url.spec.whatwg.org/#url-parsing as of 14.06.2020
    ///
    /// - parameters:
    /// 	- input:				A String, as a Collection of UTF8-encoded bytes. Null-termination is not required.
    ///     - base:					The base URL, if `input` is a relative URL string.
    ///     - url:					The URL storage to hold the parser's results.
    ///     - stateOverride:		The starting state of the parser. Used when modifying a URL.
    ///     - onValidationError:	A callback for handling any validation errors that occur.
    /// - returns:	`true` if the input was parsed successfully (in which case, `url` has been modified with the results),
    ///  			or `false` if the input could not be parsed.
    ///
    fileprivate static func _parse<C>(
        _ input: C, base: XURL.Components?, url: XURL.Components.Storage,
        stateOverride: State?, onValidationError: (ValidationError)->Void) -> Bool where C: BidirectionalCollection, C.Element == UInt8 {
        
        var input = input[...]
        
        // 1. Trim leading/trailing C0 control characters and spaces.
        let trimmedInput = input.trim {
            switch ASCII($0) {
            case ASCII.ranges.controlCharacters?: fallthrough
            case .space?:                         return true
            default: return false
            }
        }
        if trimmedInput.startIndex != input.startIndex || trimmedInput.endIndex != input.endIndex {
            onValidationError(.unexpectedC0ControlOrSpace)
        }
        input = trimmedInput

        // 2. Remove all ASCII newlines and tabs.
        func isASCIITabOrNewline(_ byte: UInt8) -> Bool {
            switch ASCII(byte) {
            case .horizontalTab?:   fallthrough
            case .lineFeed?:        fallthrough
            case .carriageReturn?:  return true
            default: _onFastPath(); return false
            }
        }
        if input.contains(where: isASCIITabOrNewline) {
            onValidationError(.unexpectedASCIITabOrNewline)
            return _parse_stateMachine(input.lazy.filter { isASCIITabOrNewline($0) == false }, base: base, url: url,
                                       stateOverride: stateOverride, onValidationError: onValidationError)
        } else {
            return _parse_stateMachine(input, base: base, url: url,
                                       stateOverride: stateOverride, onValidationError: onValidationError)
        }
    }
    
    private static func _parse_stateMachine<C>(
        _ input: C, base: XURL.Components?, url: XURL.Components.Storage,
        stateOverride: State?, onValidationError: (ValidationError)->Void) -> Bool where C: Collection, C.Element == UInt8 {

        // 3. Begin state machine.
        var state = stateOverride ?? .schemeStart

        var idx    = input.startIndex
        var buffer = [UInt8](); buffer.reserveCapacity(32)
        var flag_at = false // @flag in spec.
        var flag_passwordTokenSeen = false // passwordTokenSeenFlag in spec.
        var flag_squareBracket = false // [] flag in spec.

        inputLoop: while true {
            stateMachine: switch state {
            // Within this switch statement:
            // - inputLoop runs the switch, then advances `idx`, if `idx != input.endIndex`.
            // - stateMachine switches on `state`. It *will* see `idx == endIndex`,
            //   which turns out to be important in some of the parsing logic.
            //
            // In plain English:
            // - `break stateMachine` means "we're done processing this character, exit the switch and let inputLoop advance to the character"
            // - `break inputLoop`    means "we're done processing 'input', return whatever we have (not a failure)".
            //                        typically comes up with `stateOverride`.
            // - `return nil`         means failure.
            // - `continue`           means "loop over inputLoop again, from the beginning (**without** first advancing the character)"

            case .schemeStart:
                // Erase 'endIndex' and non-ASCII characters to `ASCII.null`.
                let c: ASCII = (idx != input.endIndex) ? ASCII(input[idx]) ?? .null : .null
                switch c {
                case _ where ASCII.ranges.isAlpha(c):
                    buffer.append(c.lowercased.codePoint)
                    state = .scheme
                    break stateMachine
                default:
                    guard stateOverride == nil else {
                        onValidationError(.invalidSchemeStart)
                        return false
                    }
                    state = .noScheme
                    continue // Do not advance index. Non-ASCII characters go through this path.
                }
                 
            case .scheme:
                // Erase 'endIndex' and non-ASCII characters to `ASCII.null`.
                let c: ASCII = (idx != input.endIndex) ? ASCII(input[idx]) ?? .null : .null
                switch c {
                case _ where ASCII.ranges.isAlphaNumeric(c), .plus, .minus, .period:
                    buffer.append(c.lowercased.codePoint)
                    break stateMachine
                case .colon:
                    break // Handled below.
                default:
                    guard stateOverride == nil else {
                        onValidationError(.invalidScheme)
                        return false
                    }
                    buffer.removeAll(keepingCapacity: true)
                    state  = .noScheme
                    idx    = input.startIndex
                    continue // Do not increment index. Non-ASCII characters go through this path.
                }
                assert(c == .colon)
                let newScheme = XURL.Scheme.parse(asciiBytes: buffer)
                if stateOverride != nil {
                    if url.scheme.isSpecial != newScheme.isSpecial {
                        break inputLoop
                    }
                    if newScheme == .file && (url.hasCredentials || url.port != nil) {
                        break inputLoop
                    }
                    if url.scheme == .file && (url.host?.isEmpty ?? true) {
                        break inputLoop
                    }
                }
                url.scheme = newScheme
                buffer.removeAll(keepingCapacity: true)
                if stateOverride != nil {
                    if url.port == url.scheme.defaultPort {
                        url.port = nil
                    }
                    break inputLoop
                }
                switch url.scheme {
                case .file:
                    state = .file
                    let nextIdx = input.index(after: idx)
                    if !input[nextIdx...].hasDoubleASCIIForwardslashPrefix() {
                        onValidationError(.fileSchemeMissingFollowingSolidus)
                    }
                case .other:
                    let nextIdx = input.index(after: idx)
                    if nextIdx != input.endIndex, ASCII(input[nextIdx]) == .forwardSlash {
                        state = .pathOrAuthority
                        idx   = nextIdx
                    } else {
                        url.cannotBeABaseURL = true
                        url.path.append("")
                        state = .cannotBeABaseURLPath
                    }
                default:
                    if base?.scheme == url.scheme {
                        state = .specialRelativeOrAuthority
                    } else {
                        state = .specialAuthoritySlashes
                    }
                }

            case .noScheme:
                // Erase 'endIndex' and non-ASCII characters to `ASCII.null`.
                let c: ASCII = (idx != input.endIndex) ? ASCII(input[idx]) ?? .null : .null
                guard let base = base else {
                    onValidationError(.missingSchemeNonRelativeURL)
                    return false
                }
                guard base.cannotBeABaseURL == false else {
                    guard c == ASCII.numberSign else {
                        onValidationError(.missingSchemeNonRelativeURL)
                        return false // Non-ASCII characters get rejected here.
                    }
                    url.scheme   = base.scheme
                    url.path     = base.path
                    url.query    = base.query
                    url.fragment = ""
                    url.cannotBeABaseURL = true
                    state = .fragment
                    break stateMachine
                }
                if base.scheme == .file {
                    state = .file
                } else {
                    state = .relative
                }
                continue // Do not increment index. Non-ASCII characters go through this path.

            case .specialRelativeOrAuthority:
                guard input[idx...].hasDoubleASCIIForwardslashPrefix() else {
                    onValidationError(.relativeURLMissingBeginningSolidus)
                    state = .relative
                    continue // Do not increment index. Non-ASCII characters go through this path.
                }
                state = .specialAuthorityIgnoreSlashes
                idx   = input.index(after: idx)

            case .pathOrAuthority:
                guard idx != input.endIndex, ASCII(input[idx]) == .forwardSlash else {
                    state = .path
                    continue // Do not increment index. Non-ASCII characters go through this path.
                }
                state = .authority

            case .relative:
                guard let base = base else {
                    // Note: The spec doesn't say what happens here if base is nil.
                    onValidationError(._baseURLRequired)
                    return false
                }
                url.scheme = base.scheme
                guard idx != input.endIndex else {
                    url.copyAuthority(from: base._storage)
                    url.path     = base.path
                    url.query    = base.query
                    break stateMachine
                }
                // Erase non-ASCII characters to `ASCII.null`.
                let c: ASCII = ASCII(input[idx]) ?? .null
                switch c {
                case .backslash where url.scheme.isSpecial:
                    onValidationError(.unexpectedReverseSolidus)
                    state = .relativeSlash
                case .forwardSlash:
                    state = .relativeSlash
                case .questionMark:
                    url.copyAuthority(from: base._storage)
                    url.path      = base.path
                    url.query     = ""
                    state         = .query
                case .numberSign:
                    url.copyAuthority(from: base._storage)
                    url.path      = base.path
                    url.query     = base.query
                    url.fragment  = ""
                    state         = .fragment
                default:
                    url.copyAuthority(from: base._storage)
                    url.path      = base.path
                    if url.path.isEmpty == false {
                    url.path.removeLast()
                    }
                    url.query     = nil
                    state         = .path
                    continue // Do not increment index. Non-ASCII characters go through this path.
                }

            case .relativeSlash:
                // Erase 'endIndex' and non-ASCII characters to `ASCII.null`.
                let c: ASCII = (idx != input.endIndex) ? ASCII(input[idx]) ?? .null : .null
                switch c {
                case .forwardSlash:
                    if url.scheme.isSpecial {
                        state = .specialAuthorityIgnoreSlashes
                    } else {
                        state = .authority
                    }
                case .backslash where url.scheme.isSpecial:
                    onValidationError(.unexpectedReverseSolidus)
                    state = .specialAuthorityIgnoreSlashes
                default:
                    guard let base = base else {
                        onValidationError(._baseURLRequired)
                        return false
                    }
                    url.copyAuthority(from: base._storage)
                    state = .path
                    continue // Do not increment index. Non-ASCII characters go through this path.
                }

            case .specialAuthoritySlashes:
                state = .specialAuthorityIgnoreSlashes
                guard input[idx...].hasDoubleASCIIForwardslashPrefix() else {
                    onValidationError(.missingSolidusBeforeAuthority)
                    continue // Do not increment index. Non-ASCII characters go through this path.
                }
                idx = input.index(after: idx)

            case .specialAuthorityIgnoreSlashes:
                // Erase 'endIndex' and non-ASCII characters to `ASCII.null`.
                // `c` is only checked against known ASCII values and never copied to the result.
                let c: ASCII = (idx != input.endIndex) ? ASCII(input[idx]) ?? .null : .null
                guard c == .forwardSlash || c == .backslash else {
                    state = .authority
                    continue // Do not increment index. Non-ASCII characters go through this path.
                }
                onValidationError(.missingSolidusBeforeAuthority)

            case .authority:
                // Erase 'endIndex' to `ASCII.forwardSlash`, as they are handled the same,
                // and `c` is not copied to the result in that case. Do not erase non-ASCII code-points.
                let c: ASCII? = (idx != input.endIndex) ? ASCII(input[idx]) : ASCII.forwardSlash
                switch c {
                case .commercialAt?:
                    onValidationError(.unexpectedCommercialAt)
                    if flag_at {
                        buffer.insert(contentsOf: "%40".utf8, at: buffer.startIndex)
                    }
                    flag_at = true
                    // Parse username and password out of "buffer".
                    // `flag_passwordTokenSeen` being true means that while looking ahead for the end of the host,
                    // we found another '@'; meaning the _first_ '@' was actually part of the password.
                    // e.g. "scheme://user:hello@world@stuff" - the password is actually "hello@world", not "hello".
                    if flag_passwordTokenSeen {
                        PercentEscaping.encodeIterativelyAsString(
                            bytes: buffer,
                            escapeSet: .url_userInfo,
                            processChunk: { piece in url.password.append(piece) }
                        )
                    } else {
                        let passwordTokenIndex = buffer.firstIndex(where: { $0 == ASCII.colon })
                        let passwordStartIndex = passwordTokenIndex.flatMap { buffer.index(after: $0) }
                        PercentEscaping.encodeIterativelyAsString(
                            bytes: buffer[..<(passwordTokenIndex ?? buffer.endIndex)],
                            escapeSet: .url_userInfo,
                            processChunk: { piece in url.username.append(piece) }
                        )
                        PercentEscaping.encodeIterativelyAsString(
                            bytes: buffer[(passwordStartIndex ?? buffer.endIndex)...],
                            escapeSet: .url_userInfo,
                            processChunk: { piece in url.password.append(piece) }
                        )
                        flag_passwordTokenSeen = (passwordTokenIndex != nil)
                    }
                    buffer.removeAll(keepingCapacity: true)
                case ASCII.forwardSlash?, ASCII.questionMark?, ASCII.numberSign?: // or endIndex.
                    fallthrough
                case ASCII.backslash? where url.scheme.isSpecial:
                    if flag_at, buffer.isEmpty {
                        onValidationError(.missingCredentials)
                        return false
                    }
                    idx    = input.index(idx, offsetBy: -1 * buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    state  = .host
                    continue // Do not increment index.
                default:
                    // This may be a non-ASCII codePoint. Append the whole thing to `buffer`.
                    guard let codePoint = input.utf8EncodedCodePoint(startingAt: idx) else {
                        onValidationError(._invalidUTF8)
                        return false
                    }
                    buffer.append(contentsOf: codePoint)
                    idx = codePoint.endIndex
                    continue // We already skipped `idx` to the end of the code-point.
                }

            case .hostname:
                fallthrough
            case .host:
                guard !(stateOverride != nil && url.scheme == .file) else {
                    state = .fileHost
                    continue // Do not increment index.
                }
                // Erase 'endIndex' to `ASCII.forwardSlash`, as they are handled the same,
                // and `c` is not copied to the result in that case. Do not erase non-ASCII code-points.
                let c: ASCII? = (idx != input.endIndex) ? ASCII(input[idx]) : ASCII.forwardSlash
                switch c {
                case .colon? where flag_squareBracket == false:
                    guard buffer.isEmpty == false else {
                        onValidationError(.unexpectedPortWithoutHost)
                        return false
                    }
                    guard let parsedHost = buffer.withUnsafeBufferPointer({
                        XURL.Host.parse($0, isNotSpecial: url.scheme.isSpecial == false,
                                        onValidationError: { onValidationError(.hostParserError($0)) })
                    }) else {
                        return false
                    }
                    url.host = parsedHost
                    buffer.removeAll(keepingCapacity: true)
                    state  = .port
                    if stateOverride == .hostname { break inputLoop }
                case .forwardSlash?, .questionMark?, .numberSign?: // or endIndex.
                    fallthrough
                case .backslash? where url.scheme.isSpecial:
                    if buffer.isEmpty {
                        if url.scheme.isSpecial {
                            onValidationError(.emptyHostSpecialScheme)
                            return false
                        } else if stateOverride != nil, (url.hasCredentials || url.port != nil) {
                            onValidationError(.hostInvalid)
                            break inputLoop
                        }
                    }
                    guard let parsedHost = buffer.withUnsafeBufferPointer({
                        XURL.Host.parse($0, isNotSpecial: url.scheme.isSpecial == false,
                                        onValidationError: { onValidationError(.hostParserError($0)) })
                    }) else {
                        return false
                    }
                    url.host = parsedHost
                    buffer.removeAll(keepingCapacity: true)
                    state  = .pathStart
                    if stateOverride != nil { break inputLoop }
                    continue // Do not increment index.
                case .leftSquareBracket?:
                    flag_squareBracket = true
                    buffer.append(ASCII.leftSquareBracket.codePoint)
                case .rightSquareBracket?:
                    flag_squareBracket = false
                    buffer.append(ASCII.rightSquareBracket.codePoint)
                default:
                    // This may be a non-ASCII codePoint. Append the whole thing to `buffer`.
                    guard let codePoint = input.utf8EncodedCodePoint(startingAt: idx) else {
                        onValidationError(._invalidUTF8)
                        return false
                    }
                    buffer.append(contentsOf: codePoint)
                    idx = codePoint.endIndex
                    continue // We already skipped `idx` to the end of the code-point.
                }

            case .port:
                // Erase 'endIndex' to `ASCII.forwardSlash` as it is handled the same and not copied to output.
                // Erase non-ASCII characters to `ASCII.null` as this state checks for specific ASCII characters/EOF.
                // `c` is only copied if it is known to be within an allowed ASCII range.
                let c: ASCII = (idx != input.endIndex) ? ASCII(input[idx]) ?? ASCII.null : ASCII.forwardSlash
                switch c {
                case ASCII.ranges.digits:
                    buffer.append(c.codePoint)
                case .forwardSlash, .questionMark, .numberSign: // or endIndex.
                    fallthrough
                case .backslash where url.scheme.isSpecial:
                    fallthrough
                case _ where stateOverride != nil:
                    if buffer.isEmpty == false {
                        guard let parsedInteger = UInt16(String(decoding: buffer, as: UTF8.self)) else {
                            onValidationError(.portOutOfRange)
                            return false
                        }
                        url.port = (parsedInteger == url.scheme.defaultPort) ? nil : parsedInteger
                        buffer.removeAll(keepingCapacity: true)
                    }
                    if stateOverride != nil { break inputLoop }
                    state = .pathStart
                    continue // Do not increment index. Non-ASCII characters go through this path.
                default:
                    onValidationError(.portInvalid)
                    return false
                }

            case .file:
                url.scheme = .file
                if idx != input.endIndex, let c = ASCII(input[idx]), (c == .forwardSlash || c == .backslash) {
                    if c == .backslash {
                        onValidationError(.unexpectedReverseSolidus)
                    }
                    state = .fileSlash
                    break stateMachine
                }
                guard let base = base, base.scheme == .file else {
                    state = .path
                    continue // Do not increment index.
                }
                url.host  = base.host
                url.path  = base.path
                url.query = base.query
                guard idx != input.endIndex else {
                    break stateMachine
                }
                switch ASCII(input[idx]) {
                case .questionMark?:
                    url.query = ""
                    state     = .query
                case .numberSign?:
                    url.fragment = ""
                    state        = .fragment
                default:
                    url.query = nil
                    if input[idx...].hasWindowsDriveLetterPrefix() {
                        onValidationError(.unexpectedWindowsDriveLetter)
                        url.host = nil
                        url.path = []
                    } else {
                        shortenURLPath(&url.path, isFileScheme: true)
                    }
                    state = .path
                    continue // Do not increment index. Non-ASCII characters go through this path.
                }

            case .fileSlash:
                if idx != input.endIndex, let c = ASCII(input[idx]), (c == .forwardSlash || c == .backslash) {
                    if c == .backslash {
                        onValidationError(.unexpectedReverseSolidus)
                    }
                    state = .fileHost
                    break stateMachine
                }
                if let base = base, base.scheme == .file,
                    input[idx...].hasWindowsDriveLetterPrefix() == false {
                    if let basePathStart = base.path.first, basePathStart.utf8.isNormalisedWindowsDriveLetter() {
                        url.path.append(basePathStart)
                    } else {
                        url.host = base.host
                    }
                }
                state = .path
                continue // Do not increment index. Non-ASCII characters go through this path.

            case .fileHost:
                // Erase 'endIndex' to `ASCII.forwardSlash` as it is handled the same and not copied to output.
                // Do not erase non-ASCII characters.
                let c: ASCII? = (idx != input.endIndex) ? ASCII(input[idx]) : ASCII.forwardSlash
                switch c {
                case .forwardSlash?, .backslash?, .questionMark?, .numberSign?: // or endIndex.
                    if stateOverride == nil, buffer.isWindowsDriveLetter() {
                        onValidationError(.unexpectedWindowsDriveLetterHost)
                        state = .path
                        // Note: buffer is intentionally not reset and used in the path-parsing state.
                    } else if buffer.isEmpty {
                        url.host = .empty
                        if stateOverride != nil { break inputLoop }
                        state = .pathStart
                    } else {
                        guard let parsedHost = buffer.withUnsafeBufferPointer({
                            XURL.Host.parse($0, isNotSpecial: false,
                                            onValidationError: { onValidationError(.hostParserError($0)) })
                        }) else {
                            return false
                        }
                        url.host = (parsedHost == .domain("localhost")) ? .empty : parsedHost
                        if stateOverride != nil { break inputLoop }
                        buffer.removeAll(keepingCapacity: true)
                        state  = .pathStart
                    }
                    continue // Do not increment index.
                default:
                    // This may be a non-ASCII codePoint. Append the whole thing to `buffer`.
                    guard let codePoint = input.utf8EncodedCodePoint(startingAt: idx) else {
                        onValidationError(._invalidUTF8)
                        return false
                    }
                    buffer.append(contentsOf: codePoint)
                    idx = codePoint.endIndex
                    continue // We already skipped `idx` to the end of the code-point.
                }

            case .pathStart:
                guard idx != input.endIndex else {
                    if url.scheme.isSpecial {
                        state = .path
                        continue // Do not increment index.
                    } else {
                        break stateMachine
                    }
                }
                // Erase non-ASCII characters to `ASCII.null` as this state checks for specific ASCII characters/EOF.
                let c: ASCII = ASCII(input[idx]) ?? ASCII.null
                switch c {
                case _ where url.scheme.isSpecial:
                    if c == .backslash {
                        onValidationError(.unexpectedReverseSolidus)
                    }
                    state = .path
                    if (c == .forwardSlash || c == .backslash) == false {
                        continue // Do not increment index. Non-ASCII characters go through this path.
                    } else {
                        break stateMachine
                    }
                case .questionMark where stateOverride == nil:
                    url.query = ""
                    state = .query
                case .numberSign where stateOverride == nil:
                    url.fragment = ""
                    state = .fragment
                default:
                    state = .path
                    if c != .forwardSlash {
                        continue // Do not increment index. Non-ASCII characters go through this path.
                    }
                }

            case .path:
                let isPathComponentTerminator: Bool =
                    (idx == input.endIndex) ||
                    (input[idx] == ASCII.forwardSlash) ||
                    (input[idx] == ASCII.backslash && url.scheme.isSpecial) ||
                    (stateOverride == nil && (input[idx] == ASCII.questionMark || input[idx] == ASCII.numberSign))
                
                guard isPathComponentTerminator else {
                    // This may be a non-ASCII codePoint.
                    guard let codePoint = input.utf8EncodedCodePoint(startingAt: idx) else {
                        onValidationError(._invalidUTF8)
                        return false
                    }
                    if hasNonURLCodePoints(codePoint, allowPercentSign: true) {
                        onValidationError(.invalidURLCodePoint)
                    }
                    if ASCII(input[idx]) == .percentSign {
                        let nextTwo = input[idx...].dropFirst().prefix(2)
                        if nextTwo.count != 2 || !nextTwo.allSatisfy({ ASCII($0)?.isHexDigit ?? false }) {
                            onValidationError(.unescapedPercentSign)
                        }
                    }
                    PercentEscaping.encodeAsBuffer(
                        singleUTF8CodePoint: codePoint,
                        escapeSet: .url_path,
                        processResult: { piece in buffer.append(contentsOf: piece) }
                    )
                    idx = codePoint.endIndex
                    continue // We already skipped `idx` to the end of the code-point.
                }
                // From here, we know:
                // - idx == endIndex, or
                // - input[idx] is one of a specific set of allowed ASCII characters
                //     (forwardSlash, backslash, questionMark or numberSign), and
                // - if input[idx] is ASCII.backslash, it implies url.isSpecial.
                //
 				// To simplify bounds-checking in the following logic, we will encode
                // the state (idx == endIndex) by the ASCII.null character.
                let c: ASCII = (idx != input.endIndex) ? ASCII(input[idx])! : ASCII.null
                if c == .backslash {
                    onValidationError(.unexpectedReverseSolidus)
                }
                switch buffer {
                case _ where buffer.isDoubleDotPathSegment():
                    shortenURLPath(&url.path, isFileScheme: url.scheme == .file)
                    fallthrough
                case _ where buffer.isSingleDotPathSegment():
                    if !(c == .forwardSlash || c == .backslash) {
                        url.path.append("")
                    }
                default:
                    if url.scheme == .file, url.path.isEmpty, buffer.isWindowsDriveLetter() {
                        if !(url.host == nil || url.host == .empty) {
                            onValidationError(.unexpectedHostFileScheme)
                            url.host = .empty
                        }
                        let secondChar = buffer.index(after: buffer.startIndex)
                        buffer[secondChar] = ASCII.colon.codePoint
                    }
                    url.path.append(String(decoding: buffer, as: UTF8.self))
                }
                buffer.removeAll(keepingCapacity: true)
                if url.scheme == .file, (c == .null /* endIndex */ || c == .questionMark || c == .numberSign) {
                    while url.path.count > 1, url.path[0].isEmpty {
                        onValidationError(.unexpectedEmptyPath)
                        url.path.removeFirst()
                    }
                }
                switch c {
                case .questionMark:
                    url.query = ""
                    state     = .query
                case .numberSign:
                    url.fragment = ""
                    state        = .fragment
                default:
                    break
                }

            case .cannotBeABaseURLPath:
                guard idx != input.endIndex else {
                    break stateMachine
                }
                let c = ASCII(input[idx])
                switch c {
                case .questionMark?:
                    url.query = ""
                    state     = .query
                case .numberSign?:
                    url.fragment = ""
                    state        = .fragment
                default:
                    // This may be a non-ASCII codePoint.
                    guard let codePoint = input.utf8EncodedCodePoint(startingAt: idx) else {
                        onValidationError(._invalidUTF8)
                        return false
                    }
                    if hasNonURLCodePoints(codePoint, allowPercentSign: true) {
                        onValidationError(.invalidURLCodePoint)
                    }
                    if ASCII(input[idx]) == .percentSign {
                        let nextTwo = input[idx...].dropFirst().prefix(2)
                        if nextTwo.count != 2 || !nextTwo.allSatisfy({ ASCII($0)?.isHexDigit ?? false }) {
                            onValidationError(.unescapedPercentSign)
                        }
                    }
                    PercentEscaping.encodeAsString(
                        singleUTF8CodePoint: codePoint,
                        escapeSet: .url_c0,
                        processResult: { piece in url.path[0].append(piece) }
                    )
                    idx = codePoint.endIndex
                    continue // We already skipped `idx` to the end of the code-point.
                }

            case .query:
                // Note: we only accept the UTF8 encoding option.
                // This parser doesn't even have an argument to choose anything else.
                guard idx != input.endIndex else { 
                    break stateMachine
                }
                if stateOverride == nil, ASCII(input[idx]) == .numberSign {
                    url.fragment = ""
                    state        = .fragment
                    break stateMachine
                }
                // This may be a non-ASCII codePoint.
                guard let codePoint = input.utf8EncodedCodePoint(startingAt: idx) else {
                    onValidationError(._invalidUTF8)
                    return false
                }
                if hasNonURLCodePoints(codePoint, allowPercentSign: true) {
                    onValidationError(.invalidURLCodePoint)
                }
                if ASCII(input[idx]) == .percentSign {
                    let nextTwo = input[idx...].dropFirst().prefix(2)
                    if nextTwo.count != 2 || !nextTwo.allSatisfy({ ASCII($0)?.isHexDigit ?? false }) {
                        onValidationError(.unescapedPercentSign)
                    }
                }
                let urlIsSpecial = url.scheme.isSpecial
                let escapeSet = PercentEscaping.EscapeSet(shouldEscape: { asciiChar in
                    switch asciiChar {
                    case .doubleQuotationMark, .numberSign, .lessThanSign, .greaterThanSign: fallthrough
                    case _ where asciiChar.codePoint < ASCII.exclamationMark.codePoint:      fallthrough
                    case _ where asciiChar.codePoint > ASCII.tilde.codePoint:                fallthrough
                    case .apostrophe where urlIsSpecial: return true
                    default: return false
                    }
                })
                PercentEscaping.encodeAsString(
                    singleUTF8CodePoint: codePoint,
                    escapeSet: escapeSet,
                    processResult: { escapedChar in
                        if url.query == nil {
                            url.query = escapedChar
                        } else {
                            url.query!.append(escapedChar)
                        }
                })
                idx = codePoint.endIndex
                continue // We already skipped `idx` to the end of the code-point.

            case .fragment:
                guard idx != input.endIndex else {
                    break stateMachine
                }
                // This may be a non-ASCII codePoint.
                guard let codePoint = input.utf8EncodedCodePoint(startingAt: idx) else {
                    onValidationError(._invalidUTF8)
                    return false
                }
                if hasNonURLCodePoints(codePoint, allowPercentSign: true) {
                    onValidationError(.invalidURLCodePoint)
                }
                if ASCII(input[idx]) == .percentSign {
                    let nextTwo = input[idx...].dropFirst().prefix(2)
                    if nextTwo.count != 2 || !nextTwo.allSatisfy({ ASCII($0)?.isHexDigit ?? false }) {
                        onValidationError(.unescapedPercentSign)
                    }
                }
                PercentEscaping.encodeAsString(
                    singleUTF8CodePoint: codePoint,
                    escapeSet: .url_fragment,
                    processResult: { escapedChar in
                        if url.fragment == nil {
                            url.fragment = escapedChar
                        } else {
                            url.fragment?.append(escapedChar)
                        }
                })
                idx = codePoint.endIndex
                continue // We already skipped `idx` to the end of the code-point.
                
            } // end of `stateMachine: switch state {`

            if idx == input.endIndex { break }
			assert(ASCII(input[idx]) != nil, """
                      This should only be reached if we have an ASCII character.
                      Other characters should have been funelled to a unicode-aware state,
                      which should consume entire code-points until some other ASCII character.
                   """)
            idx = input.index(after: idx)
            
        } // end of `inputLoop: while true {`

        return true
    }
    

    static func shortenURLPath(_ path: inout [String], isFileScheme: Bool) {
        guard path.isEmpty == false else { return }
        if isFileScheme, path.count == 1, path[0].utf8.isNormalisedWindowsDriveLetter() { return }
        path.removeLast()
    }
}
