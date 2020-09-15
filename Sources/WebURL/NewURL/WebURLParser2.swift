
public struct NewURL {
  var storage: Storage = .init(capacity: 0, initialHeader: .init())
  
  init(storage: Storage) {
    self.storage = storage
  }
  
  public init?(_ input: String, base: String?) {
    var baseURL: NewURL?
    if let baseString = base {
      baseURL = NewURLParser().constructURL(input: baseString.utf8, baseURL: nil)
    }
    guard let url = NewURLParser().constructURL(input: input.utf8, baseURL: baseURL) else {
      return nil
    }
    self = url
  }
}

extension NewURL {
  
  typealias Storage = ArrayWithInlineHeader<URLHeader<Int>, UInt8>
  
  enum Component {
    case scheme, username, password, hostname, port, path, query, fragment
    case authority
  }
  
  func withComponentBytes<T>(_ component: Component, _ block: (UnsafeBufferPointer<UInt8>?) -> T) -> T {
    guard let range = storage.header.rangeOfComponent(component) else { return block(nil) }
    return storage.withElements(range: range) { buffer in block(buffer) }
  }
  
  func stringForComponent(_ component: Component) -> String? {
    return withComponentBytes(component) { maybeBuffer in
      return maybeBuffer.map { buffer in String(decoding: buffer, as: UTF8.self) }
    }
  }

  var schemeKind: NewURLParser.Scheme {
    return storage.header.schemeKind
  }
  
  public var scheme: String {
    return stringForComponent(.scheme)!
  }
  
  // Note: erasure to empty strings is done to fit the Javascript model for WHATWG tests.
  
  public var username: String {
    return stringForComponent(.username) ?? ""
  }
  
  public var password: String {
    var string = stringForComponent(.password)
    if !(string?.isEmpty ?? true) {
      let separator = string?.removeFirst()
      assert(separator == ":")
    }
    return string ?? ""
  }
  
  public var hostname: String {
    return stringForComponent(.hostname) ?? ""
  }
  
  public var port: String {
    var string = stringForComponent(.port)
    if !(string?.isEmpty ?? true) {
      let separator = string?.removeFirst()
      assert(separator == ":")
    }
    return string ?? ""
  }
  
  public var path: String {
    return stringForComponent(.path) ?? ""
  }
  
  public var query: String {
    let string = stringForComponent(.query)
    guard string != "?" else { return "" }
    return string ?? ""
  }
  
  public var fragment: String {
    let string = stringForComponent(.fragment)
    guard string != "#" else { return "" }
    return string ?? ""
  }
  
  public var cannotBeABaseURL: Bool {
    return storage.header.cannotBeABaseURL
  }
  
  public var href: String {
    return storage.asUTF8String()
  }
}

extension NewURL: CustomStringConvertible {
  
  public var description: String {
    return
      """
      URL Constructor output:
      
      Href: \(href)
      
      Scheme: \(scheme) (\(schemeKind))
      Username: \(username)
      Password: \(password)
      Hostname: \(hostname)
      Port: \(port)
      Path: \(path)
      Query: \(query)
      Fragment: \(fragment)
      CannotBeABaseURL: \(cannotBeABaseURL)
      """
  }
}

/// A header for storing a generic absolute URL.
///
/// The stored URL must be of the format:
///  [scheme + ":"] + ["//"]? + [username]? + [":" + password] + ["@"]? + [hostname]? + [":" + port]? + ["/" + path]? + ["?" + query]? + ["#" + fragment]?
///
struct URLHeader<SizeType: BinaryInteger>: InlineArrayHeader {
  var _count: SizeType = 0
  
  var components: ComponentsToCopy = [] // TODO: Rename type.
  var schemeKind: NewURLParser.Scheme = .other
  var schemeLength: SizeType = 0
  var usernameLength: SizeType = 0
  var passwordLength: SizeType = 0
  var hostnameLength: SizeType = 0
  var portLength: SizeType = 0
  // if path, query or fragment are not 0, they must contain their leading separators ('/', '?', '#').
  var pathLength: SizeType = 0
  var queryLength: SizeType = 0
  var fragmentLength: SizeType = 0
  var cannotBeABaseURL: Bool = false
  
  var count: Int {
    get { return Int(_count) }
    set { _count = SizeType(newValue) }
  }
  
  // Scheme is always present and starts at byte 0.
  
  var schemeStart: SizeType {
    assert(components.contains(.scheme), "URLs must always have a scheme")
    return 0
  }
    
  var schemeEnd: SizeType {
    schemeStart + schemeLength
  }
  
  // Authority may or may not be present.
  
  // - If present, it starts at schemeEnd + 2 ('//').
  //   - It may be an empty string for non-special URLs ("pop://?hello").
  // - If not present, do not add double solidus ("pop:?hello").
  //
  // The difference is that "pop://?hello" has an empty authority, and "pop:?hello" has a nil authority.
  // The output of the URL parser preserves that, so we need to factor that in to our component offset calculations.
  
  var authorityStart: SizeType {
    return schemeEnd + (components.contains(.authority) ? 2 : 0 /* // */)
  }
  
  var usernameStart: SizeType {
    return authorityStart
  }
  var passwordStart: SizeType {
    return usernameStart + usernameLength
  }
  var hostnameStart: SizeType {
    return passwordStart + passwordLength
      + (usernameLength == 0 && passwordLength == 0 ? 0 : 1) /* @ */
  }
  var portStart: SizeType {
    return hostnameStart + hostnameLength
  }
  
  // Components with leading separators.
  // The 'start' position is the offset of the separator character ('/','?','#'), and
  // this additional character is included in the component's length.
  // Non-present components have a length of 0.
  
  // For example, "pop://example.com" has a queryLength of 0, but "pop://example.com?" has a queryLength of 1.
  // The former has an empty query component, the latter has a 'nil' query component.
  // The parser has to preserve the separator, even if the component is empty.
  
  /// Returns the end of the authority section, if one is present.
  /// Any trailing components (path, query, fragment) start from here.
  ///
  var pathStart: SizeType {
    return components.contains(.authority) ? (portStart + portLength) : schemeEnd
  }
  
  /// Returns the position of the leading '?' in the query-string, if one is present. Otherwise, returns the position after the path.
  /// All query strings start with a '?'.
  ///
  var queryStart: SizeType {
    return pathStart + pathLength
  }
  
  /// Returns the position of the leading '#' in the fragment, if one is present. Otherwise, returns the position after the query-string.
  /// All fragments start with a '#'.
  ///
  var fragmentStart: SizeType {
    return queryStart + queryLength
  }
  
  func rangeOfComponent(_ component: NewURL.Component) -> Range<SizeType>? {
    let start: SizeType
    let length: SizeType
    switch component {
    case .scheme:
      assert(schemeLength > 1)
      return Range(uncheckedBounds: (schemeStart, schemeEnd))
      
    case .hostname:
      guard components.contains(.authority) else { return nil }
      start = hostnameStart
      length = hostnameLength
      
    // FIXME: Move this to its own function instead of making it a fake component.
    // Convenience component for copying a URL's entire authority string.
    case .authority:
      guard components.contains(.authority) else { return nil }
      return authorityStart ..< pathStart
    
    // Optional authority details.
    // These have no distinction between empty and nil values, because lone separators are not preserved.
    // e.g. "http://:@test.com" -> "http://test.com".
    case .username:
      guard components.contains(.authority), usernameLength != 0 else { return nil }
      start = usernameStart
      length = usernameLength
    // Password and port have leading separators, but lone separators should never exist.
    case .password:
      assert(passwordLength != 1)
      guard components.contains(.authority), passwordLength > 1 else { return nil }
      start = passwordStart
      length = passwordLength
    case .port:
      assert(portLength != 1)
      guard components.contains(.authority), portLength > 1 else { return nil }
      start = portStart
      length = portLength

    // Components with leading separators.
    // Lone separators are preserved in some cases, which is marked by a length of 1.
    // A length of 0 means a nil value.
    case .path:
      guard components.contains(.path), pathLength != 0 else { return nil }
      start = pathStart
      length = pathLength
    case .query:
      guard components.contains(.query), queryLength != 0 else { return nil }
      start = queryStart
      length = queryLength
    case .fragment:
      guard components.contains(.fragment), fragmentLength != 0 else { return nil }
      start = fragmentStart
      length = fragmentLength
    }
    return start ..< (start + length)
  }
}




enum ParsableComponent {
   case scheme
   case authority
   case host
   case port
   case pathStart // better name?
   case path
   case query
   case fragment
}

struct ComponentsToCopy: OptionSet {
  typealias RawValue = UInt8
  
  var rawValue: RawValue
  init(rawValue: RawValue) {
    self.rawValue = rawValue
  }
  
  static var scheme: Self    { Self(rawValue: 1 << 0) }
  static var authority: Self { Self(rawValue: 1 << 1) }
  static var path: Self      { Self(rawValue: 1 << 2) }
  static var query: Self     { Self(rawValue: 1 << 3) }
  static var fragment: Self  { Self(rawValue: 1 << 4) }
}

// --------------------------------
// Compressed optionals
// --------------------------------
// Unused right now, but the idea is that instead of having Mapping<Input.Index>, we'd
// have some overridden entrypoints which can, for example, compress an Optional<Int> (9 bytes on x86_64)
// in to something like an Optional<UInt15>, where the high bit is reserved to indicate nil, and we have 5 bits of
// magnitude (allowing indexing up to 32,768 bytes - which ought to be enough for most URLs).
//
// This means significant stack savings, better cache usage, and hopefully faster runtime overall.
//

protocol CompressedOptional {
  associatedtype Wrapped
  
  static var none: Self { get }
  func get() -> Wrapped?
  mutating func set(to newValue: Wrapped?)
}

extension Optional: CompressedOptional {
  static var none: Optional<Wrapped> {
    return nil
  }
  func get() -> Wrapped? {
    return self
  }
  mutating func set(to newValue: Wrapped?) {
    self = newValue
  }
}

struct CompressedOptionalUnsignedInteger<Base: SignedInteger & BinaryInteger & FixedWidthInteger>: CompressedOptional {
  private var base: Base
  init() {
    self.base = -1
  }
  
  typealias Wrapped = Base
  static var none: Self {
    return Self()
  }
  func get() -> Wrapped? {
    return base >= 0 ? base : nil
  }
  mutating func set(to newValue: Wrapped?) {
    guard let newValue = newValue else {
      self.base = -1
      return
    }
    precondition(newValue.magnitude <= Base.Magnitude(1 << (Base.Magnitude.bitWidth - 1)))
    self.base = newValue
  }
}

struct Mapping<IndexStorage: CompressedOptional> {
  typealias Index = IndexStorage.Wrapped
  
  var cannotBeABaseURL = false
  var componentsToCopyFromBase: ComponentsToCopy = []
  
  var schemeKind: NewURLParser.Scheme? = nil
  // This is the index of the scheme terminator (":"), if one exists.
  var schemeTerminator = IndexStorage.none
  
  // This is the index of the first character of the authority segment, if one exists.
  // The scheme and authority may be separated by an arbitrary amount of trivia.
  // The authority ends at the "*EndIndex" of the last of its components.
  var authorityStartPosition = IndexStorage.none
  
    // This is the endIndex of the authority's username component, if one exists.
    // The username starts at the authorityStartPosition.
    var usernameEndIndex = IndexStorage.none
  
    // This is the endIndex of the password, if one exists.
    // If a password exists, a username must also exist, and usernameEndIndex must be the ":" character.
    // The password starts at the index after usernameEndIndex.
    var passwordEndIndex = IndexStorage.none

// TODO (hostname): What if there is no authorityStartPosition? Is it guaranteed to be set?
  
    // This is the endIndex of the hostname, if one exists.
    // The hostname starts at the index after (username/password)EndIndex,
    // or from authorityStartPosition if there are no credentials.
    var hostnameEndIndex = IndexStorage.none
  
    // This is the endIndex of the port-string, if one exists.
    // If a port-string exists, a hostname must also exist, and hostnameEndIndex must be the ":" character.
    // The port-string starts at the index after hostnameEndIndex.
    var portEndIndex = IndexStorage.none
  
  // This is the endIndex of the path, if one exists.
  // If an authority segment exists, the path starts at the index after the end of the authority.
  // Otherwise, it starts at the index 2 places after 'schemeTerminator' (":" + "/" or "\").
  var path = IndexStorage.none
  
  var query = IndexStorage.none
  var fragment = IndexStorage.none
}

struct NewURLParser {
  
  init() {}
  
  /// Constructs a new URL from the given input string, interpreted relative to the given (optional) base URL.
  ///
	func constructURL<Input>(
    input: Input,
    baseURL: NewURL?
  ) -> NewURL? where Input: BidirectionalCollection, Input.Element == UInt8 {
    
    // There are 2 phases to constructing a new URL: scanning and construction.
    //
    // - Scanning:     Determine if the input is at all parseable, and which parts of `input`
    //                 contribute to which components.
    // - Construction: Use the information from the scanning step, together with the base URL,
    //                 to transform and copy the pieces of each component in to a final result.
    
    let filteredInput = FilteredURLInput(input, isSetterMode: false)
    
    var callback = CollectValidationErrors()
  
    guard let scanResults = scanURL(filteredInput, baseURL: baseURL,
                                    mappingType: Mapping<Optional<Input.Index>>.self, stateOverride: nil,
                                    callback: &callback) else {
      return nil
    }
    
    print("")
    print("Scanning Errors:")
    print("-----------------------------------------")
    callback.errors.forEach { print($0.description); print("---") }
    print("-----------------------------------------")
    print("")
    callback.errors.removeAll(keepingCapacity: true)
    
    let result = construct(url: scanResults, input: filteredInput, baseURL: baseURL, callback: &callback)
    
    print("")
    print("Construction Errors:")
    print("-----------------------------------------")
    callback.errors.forEach { print($0.description); print("---") }
    print("-----------------------------------------")
    print("")
    
    return result
  }
  
  func construct<Input, T, Callback>(
    url: Mapping<T>,
    input: FilteredURLInput<Input>,
    baseURL: NewURL?,
    callback: inout Callback
  ) -> NewURL? where Mapping<T>.Index == Input.Index, Callback: URLParserCallback {
    
    var url = url
    
    // The mapping does not contain full ranges. They must be inferred using our knowledge of URL structure.
    // Some components require additional validation (e.g. the port), and others require adjustments based on
    // full knowledge of the URL string (e.g. if a file URL whose path starts with a Windows drive, clear the host).
    
    let schemeRange = url.schemeTerminator.get().map { input.startIndex..<$0 }
    var usernameRange: Range<Input.Index>?
    var passwordRange: Range<Input.Index>?
    var hostnameRange: Range<Input.Index>?
    var port: UInt16?
    let pathRange: Range<Input.Index>?
    let queryRange: Range<Input.Index>?
    let fragmentRange: Range<Input.Index>?

    var cursor: Input.Index
    
    let schemeKind: NewURLParser.Scheme
    if let scannedSchemeKind = url.schemeKind {
      schemeKind = scannedSchemeKind
    } else if url.componentsToCopyFromBase.contains(.scheme), let baseURL = baseURL {
      schemeKind = baseURL.schemeKind
    } else {
      preconditionFailure("We must have a scheme")
    }
    
    if let authorityStart = url.authorityStartPosition.get() {
      cursor = authorityStart
      if let usernameEnd = url.usernameEndIndex.get() {
        usernameRange = cursor..<usernameEnd
        cursor = usernameEnd
        
        if let passwordEnd = url.passwordEndIndex.get() {
          assert(input[cursor] == ASCII.colon.codePoint)
          cursor = input.index(after: cursor)
          
          passwordRange = cursor..<passwordEnd
          cursor = passwordEnd
          assert(input[cursor] == ASCII.commercialAt.codePoint)
          cursor = input.index(after: cursor)
        } else {
          assert(input[cursor] == ASCII.commercialAt.codePoint) // "https://test:@test"
          cursor = input.index(after: cursor)
        }
      }
      hostnameRange = url.hostnameEndIndex.get().map { hostnameEndIndex in
        cursor..<hostnameEndIndex
      }
      cursor = hostnameRange.map { $0.upperBound } ?? cursor
      // Port: Validate that the number doesn't overflow a UInt16.
      if let portStringEndIndex = url.portEndIndex.get() {
        cursor = input.index(after: cursor) // ":" hostname separator.
        if portStringEndIndex != cursor {
          guard let parsedInteger = UInt16(String(decoding: input[cursor..<portStringEndIndex], as: UTF8.self)) else {
            callback.validationError(.portOutOfRange)
            return nil
          }
          port = parsedInteger
          cursor = portStringEndIndex
        }
      }
    } else if let schemeRange = schemeRange {
      cursor = input.index(after: schemeRange.upperBound) // ":" scheme separator.
    } else {
      cursor = input.startIndex
    }
    
    pathRange = url.path.get().map { pathEndIndex -> Range<Input.Index> in
      defer { cursor = pathEndIndex }
      let pathStart = cursor
      // For file URLs whose paths begin with a Windows drive letter, discard the host.
      if cursor != input.endIndex {
        // The path may or may not be prefixed with a leading slash.
      	// Strip it so we can detect the Windows drive letter.
        switch ASCII(input[cursor]) {
        case .forwardSlash?: fallthrough
        case .backslash? where schemeKind.isSpecial:
          cursor = input.index(after: cursor)
        default:
          break
        }
      }
      if schemeKind == .file, URLStringUtils.hasWindowsDriveLetterPrefix(input[cursor...]) {
        if !(hostnameRange == nil || hostnameRange?.isEmpty == true) {
          callback.validationError(.unexpectedHostFileScheme)
          hostnameRange = nil // file URLs turn 'nil' in to an implicit, empty host.
        }
        url.componentsToCopyFromBase.remove(.authority)
      }
      return pathStart..<pathEndIndex
    }
    queryRange = url.query.get().map { queryEndIndex -> Range<Input.Index> in
      cursor = input.index(after: cursor) // "?" query separator.
      defer { cursor = queryEndIndex }
      return cursor..<queryEndIndex
    }
    fragmentRange = url.fragment.get().map { fragmentEndIndex -> Range<Input.Index> in
      cursor = input.index(after: cursor) // "#" fragment separator.
      defer { cursor = fragmentEndIndex }
      return cursor..<fragmentEndIndex
    }
    
    // Construct an absolute URL string from the ranges, as well as the baseURL and components to copy.
    
    var newstorage = NewURL.Storage(capacity: 10, initialHeader: .init())
    newstorage.header.cannotBeABaseURL = url.cannotBeABaseURL
    
    // We *must* have a scheme.
    if let inputScheme = schemeRange {
      assert(schemeKind == url.schemeKind)
      // Scheme must be lowercased.
      newstorage.append(contentsOf: input[inputScheme].lazy.map {
        ASCII($0)?.lowercased.codePoint ?? $0
      })
      newstorage.append(ASCII.colon.codePoint) // Scheme separator (':').
      newstorage.header.schemeLength = newstorage.count
      newstorage.header.components = [.scheme]
    } else {
      guard let baseURL = baseURL, url.componentsToCopyFromBase.contains(.scheme) else {
      	preconditionFailure("Cannot construct a URL without a scheme")
      }
      assert(schemeKind == baseURL.schemeKind)
      baseURL.withComponentBytes(.scheme) { newstorage.append(contentsOf: $0!) }
      newstorage.header.schemeLength = baseURL.storage.header.schemeLength
      newstorage.header.components = [.scheme]
    }
    newstorage.header.schemeKind = schemeKind
    
    
    if let host = hostnameRange {
      newstorage.append(repeated: ASCII.forwardSlash.codePoint, count: 2) // Authority marker ('//').
      newstorage.header.components.insert(.authority)
      
      var hasCredentials = false
      if let username = usernameRange, username.isEmpty == false {
        PercentEscaping.encodeIterativelyAsBuffer(
          bytes: input[username],
          escapeSet: .url_userInfo,
          processChunk: { piece in newstorage.append(contentsOf: piece); newstorage.header.usernameLength += piece.count }
        )
        hasCredentials = true
      }
      if let password = passwordRange, password.isEmpty == false {
        newstorage.append(ASCII.colon.codePoint) // Username-password separator (':').
        newstorage.header.passwordLength = 1
        PercentEscaping.encodeIterativelyAsBuffer(
          bytes: input[password],
          escapeSet: .url_userInfo,
          processChunk: { piece in newstorage.append(contentsOf: piece); newstorage.header.passwordLength += piece.count }
        )
        hasCredentials = true
      }
      if hasCredentials {
        newstorage.append(ASCII.commercialAt.codePoint) // Credentials separator.
      }
    
      // FIXME: Hostname needs improving.
      let _hostnameString = Array(input[host]).withUnsafeBufferPointer { bytes -> String? in
        return WebURLParser.Host.parse(bytes, isNotSpecial: schemeKind.isSpecial == false, callback: &callback)?.serialized
      }
      guard let hostnameString = _hostnameString else { return nil }
      if !(schemeKind == .file && hostnameString == "localhost") {
        newstorage.append(contentsOf: hostnameString.utf8)
        newstorage.header.hostnameLength = hostnameString.utf8.count
      }
      
      if let port = port, port != schemeKind.defaultPort {
        newstorage.append(ASCII.colon.codePoint) // Hostname-port separator.
        let portStringBytes = String(port).utf8
        newstorage.append(contentsOf: portStringBytes)
        newstorage.header.portLength = 1 + portStringBytes.count
      }
      
    } else if url.componentsToCopyFromBase.contains(.authority) {
      guard let baseURL = baseURL else {
        preconditionFailure("")
      }
      baseURL.withComponentBytes(.authority) {
        if let baseAuth = $0 {
          newstorage.append(repeated: ASCII.forwardSlash.codePoint, count: 2) // Authority marker ('//').
          newstorage.append(contentsOf: baseAuth)
          newstorage.header.usernameLength = baseURL.storage.header.usernameLength
          newstorage.header.passwordLength = baseURL.storage.header.passwordLength
          newstorage.header.hostnameLength = baseURL.storage.header.hostnameLength
          newstorage.header.portLength = baseURL.storage.header.portLength
          newstorage.header.components.insert(.authority)
        }
      }
    } else if schemeKind == .file {
      // - 'file:' URLs get an implicit authority.
      // -
      newstorage.append(repeated: ASCII.forwardSlash.codePoint, count: 2)
      newstorage.header.components.insert(.authority)
    }
    
    
    // Write path.
    if let path = pathRange {
      newstorage.header.components.insert(.path)
      switch url.cannotBeABaseURL {
      case true:
        PercentEscaping.encodeIterativelyAsBuffer(
          bytes: input[path],
          escapeSet: .url_c0,
          processChunk: { piece in newstorage.append(contentsOf: piece); newstorage.header.pathLength += piece.count }
        )
      case false:
        
        var pathLength = 0
        if url.componentsToCopyFromBase.contains(.path) {
          // FIXME: We are double-escaping the base-URL's path.
          iterateAppendedPathComponents(input[path], baseURL: baseURL!, schemeIsSpecial: schemeKind.isSpecial, isFileScheme: schemeKind == .file) { _, pathComponent in
            pathLength += 1
            PercentEscaping.encodeIterativelyAsBuffer(bytes: pathComponent, escapeSet: .url_path) { pathLength += $0.count }
          }
        } else {
          iteratePathComponents(input[path], schemeIsSpecial: schemeKind.isSpecial, isFileScheme: schemeKind == .file) { _, pathComponent in
            pathLength += 1
            PercentEscaping.encodeIterativelyAsBuffer(bytes: pathComponent, escapeSet: .url_path) { pathLength += $0.count }
          }
        }
        
        assert(pathLength > 0)
        var buffer = [UInt8](repeatElement(0, count: pathLength))
        buffer.withUnsafeMutableBufferPointer { mutBuffer in
          
          var front = mutBuffer.endIndex
          func handlePathComponent(_ isFirstComponent: Bool, _ pathComponent: AnyBidirectionalCollection<UInt8>) {
            if pathComponent.isEmpty {
              front = mutBuffer.index(before: front)
              mutBuffer[front] = ASCII.forwardSlash.codePoint
              newstorage.header.pathLength += 1
              return
            }
            
            if isFirstComponent, schemeKind == .file, URLStringUtils.isWindowsDriveLetter(pathComponent) {
              front = mutBuffer.index(before: front)
              mutBuffer[front] = ASCII.colon.codePoint
              front = mutBuffer.index(before: front)
              mutBuffer[front] = pathComponent[pathComponent.startIndex]
              newstorage.header.pathLength += 2
            } else {
              PercentEscaping.encodeReverseIterativelyAsBuffer(
                bytes: pathComponent,
                escapeSet: .url_path,
                processChunk: { piece in
                  let newFront = mutBuffer.index(front, offsetBy: -1 * piece.count)
                  _ = UnsafeMutableBufferPointer(rebasing: mutBuffer[newFront...]).initialize(from: piece)
                  front = newFront
                  newstorage.header.pathLength += piece.count
              })
            }
            front = mutBuffer.index(before: front)
            mutBuffer[front] = ASCII.forwardSlash.codePoint
            newstorage.header.pathLength += 1
          }
          
          if url.componentsToCopyFromBase.contains(.path) {
            iterateAppendedPathComponents(input[path], baseURL: baseURL!, schemeIsSpecial: schemeKind.isSpecial, isFileScheme: schemeKind == .file,
                                          handlePathComponent)
          } else {
            iteratePathComponents(input[path], schemeIsSpecial: schemeKind.isSpecial, isFileScheme: schemeKind == .file) {
              handlePathComponent($0, AnyBidirectionalCollection($1))
            }
          }
        }
        assert(buffer.count == pathLength)
        newstorage.append(contentsOf: buffer.suffix(pathLength))
        newstorage.header.pathLength = pathLength
      }
      
    } else if url.componentsToCopyFromBase.contains(.path) {
      guard let baseURL = baseURL else { preconditionFailure("") }
      baseURL.withComponentBytes(.path) {
        if let basePath = $0 {
          newstorage.append(contentsOf: basePath)
          newstorage.header.pathLength = baseURL.storage.header.pathLength
          newstorage.header.components.insert(.path)
        }
      }
    } else if schemeKind.isSpecial {
      // Special URLs always have a '/' following the authority, even if they have no path.
      newstorage.append(ASCII.forwardSlash.codePoint)
      newstorage.header.pathLength = 1
      newstorage.header.components.insert(.path)
    }
    
    // Write query.
    if let query = queryRange {
      newstorage.append(ASCII.questionMark.codePoint)
      newstorage.header.queryLength = 1
      newstorage.header.components.insert(.query)
      
      let urlIsSpecial = schemeKind.isSpecial
      let escapeSet = PercentEscaping.EscapeSet(shouldEscape: { asciiChar in
        switch asciiChar {
        case .doubleQuotationMark, .numberSign, .lessThanSign, .greaterThanSign,
          _ where asciiChar.codePoint < ASCII.exclamationMark.codePoint,
          _ where asciiChar.codePoint > ASCII.tilde.codePoint, .apostrophe where urlIsSpecial:
          return true
        default: return false
        }
      })
      PercentEscaping.encodeIterativelyAsBuffer(
        bytes: input[query],
        escapeSet: escapeSet,
        processChunk: { piece in newstorage.append(contentsOf: piece); newstorage.header.queryLength += piece.count }
      )
    } else if url.componentsToCopyFromBase.contains(.query) {
      guard let baseURL = baseURL else { preconditionFailure("") }
      baseURL.withComponentBytes(.query) { newstorage.append(contentsOf: $0 ?? UnsafeBufferPointer(start: nil, count: 0)) }
      newstorage.header.queryLength = baseURL.storage.header.queryLength
      newstorage.header.components.insert(.query)
    }
    
    // Write fragment.
    if let fragment = fragmentRange {
      newstorage.append(ASCII.numberSign.codePoint)
      newstorage.header.fragmentLength = 1
      newstorage.header.components.insert(.fragment)
      PercentEscaping.encodeIterativelyAsBuffer(
        bytes: input[fragment],
        escapeSet: .url_fragment,
        processChunk: { piece in newstorage.append(contentsOf: piece); newstorage.header.fragmentLength += piece.count }
      )
    } else if url.componentsToCopyFromBase.contains(.fragment) {
      guard let baseURL = baseURL else { preconditionFailure("") }
      baseURL.withComponentBytes(.fragment) { newstorage.append(contentsOf: $0!) }
      newstorage.header.fragmentLength = baseURL.storage.header.fragmentLength
      newstorage.header.components.insert(.fragment)
    }
    
    return NewURL(storage: newstorage)
  }
}

// --------------------------------------
// FilteredURLInput
// --------------------------------------
//
// A byte sequence with leading/trailing spaces trimmed,
// and which lazily skips ASCII newlines and tabs.
//
// We need this hoisted out so that the scanning and construction phases
// both see the same bytes. The mapping produced by the scanning phase is only meaningful
// with respect to this collection.
//
// Some future optimisation ideas:
//
// 1. Scan the byte sequence to check if it even needs to skip characters.
//    Store it as an `Either<LazyFilterSequence<...>, Base>`.
//
// 2. When constructing, look for regions where we can access regions of `Base` contiguously (region-based filtering).
//


struct FilteredURLInput<Base> where Base: BidirectionalCollection, Base.Element == UInt8 {
  var base: LazyFilterSequence<Base.SubSequence>
  
  init(_ rawInput: Base, isSetterMode: Bool) {
    // 1. Trim leading/trailing C0 control characters and spaces.
    var trimmedSlice = rawInput[...]
    if isSetterMode == false {
      let trimmedInput = trimmedSlice.trim {
        switch ASCII($0) {
        case ASCII.ranges.controlCharacters?, .space?: return true
        default: return false
        }
      }
      if trimmedInput.startIndex != trimmedSlice.startIndex || trimmedInput.endIndex != trimmedSlice.endIndex {
//        callback.validationError(.unexpectedC0ControlOrSpace)
      }
      trimmedSlice = trimmedInput
    }
    
    // 2. Filter all ASCII newlines and tabs.
    let input = trimmedSlice.lazy.filter {
      ASCII($0) != .horizontalTab
      && ASCII($0) != .carriageReturn
      && ASCII($0) != .lineFeed
    }

    // TODO: 3. Skip to unicode code-point boundaries.
    
    self.base = input
  }
}

extension FilteredURLInput: BidirectionalCollection {
  typealias Index = Base.Index
  typealias Element = Base.Element
  
  var startIndex: Index {
    return base.startIndex
  }
  var endIndex: Index {
    return base.endIndex
  }
  var count: Int {
    return base.count
  }
  func index(after i: Base.Index) -> Base.Index {
    return base.index(after: i)
  }
  func index(before i: Base.Index) -> Base.Index {
    return base.index(before: i)
  }
  func index(_ i: Base.Index, offsetBy distance: Int, limitedBy limit: Base.Index) -> Base.Index? {
    return base.index(i, offsetBy: distance, limitedBy: limit)
  }
  func distance(from start: Base.Index, to end: Base.Index) -> Int {
    return base.distance(from: start, to: end)
  }
  subscript(position: Base.Index) -> UInt8 {
    return base[position]
  }
}

// --------------------------------------
// URL Scanning
// --------------------------------------
//
// `scanURL` is the entrypoint, and calls in to scanning methods written
// as static functions on the generic `URLScanner` type. This is to avoid constraint duplication,
// as all the scanning methods basically share the same constraints (except the entrypoint itself, which is slightly different).
//

/// The first stage is scanning, where we want to build up a map of the resulting URL's components.
/// This will tell us whether the URL is structurally invalid, although it may still fail to normalize if the domain name is nonsense.
///
func scanURL<Input, T, Callback>(
  _ input: FilteredURLInput<Input>,
  baseURL: NewURL?,
  mappingType: Mapping<T>.Type,
  stateOverride: WebURLParser.ParserState? = nil,
  callback: inout Callback
) -> Mapping<T>? where Mapping<T>.Index == Input.Index, Callback: URLParserCallback {
  
  var scanResults = Mapping<T>()
  let success: Bool
  
  if let schemeEndIndex = findScheme(input) {
    
    let schemeNameBytes = input[..<schemeEndIndex].dropLast() // dropLast() to remove the ":" terminator.
    let scheme = NewURLParser.Scheme.parse(asciiBytes: schemeNameBytes)
    
    scanResults.schemeKind = scheme
    scanResults.schemeTerminator.set(to: input.index(before: schemeEndIndex))
    success = URLScanner.scanURLWithScheme(input[schemeEndIndex...], scheme: scheme, baseURL: baseURL, &scanResults, callback: &callback)
    
  } else {
		// If we don't have a scheme, we'll need to copy from the baseURL.
    guard let base = baseURL else {
      callback.validationError(.missingSchemeNonRelativeURL)
      return nil
    }
    // If base `cannotBeABaseURL`, the only thing we can do is set the fragment.
    guard base.cannotBeABaseURL == false else {
      guard ASCII(flatMap: input.first) == .numberSign else {
        callback.validationError(.missingSchemeNonRelativeURL)
        return nil
      }
      scanResults.componentsToCopyFromBase = [.scheme, .path, .query]
      scanResults.cannotBeABaseURL = true
      if case .failed = URLScanner.scanFragment(input.dropFirst(), &scanResults, callback: &callback) {
        success = false
      } else {
        success = true
      }
      return success ? scanResults : nil
    }
    // (No scheme + valid base URL) = some kind of relative-ish URL.
    if base.schemeKind == .file {
      scanResults.componentsToCopyFromBase = [.scheme]
      success = URLScanner.scanAllFileURLComponents(input[...], baseURL: baseURL, &scanResults, callback: &callback)
    } else {
      success = URLScanner.scanAllRelativeURLComponents(input[...], baseScheme: base.schemeKind, &scanResults, callback: &callback)
    }
  }
  
  // End parse function.
  return success ? scanResults : nil
}

/// Returns the endIndex of the scheme (i.e. index of the scheme terminator ":") if one can be parsed from `input`.
/// Otherwise returns `nil`.
///
private func findScheme<Input>(_ input: FilteredURLInput<Input>) -> Input.Index? {
  
  guard input.isEmpty == false else { return nil }
  var cursor = input.startIndex
  
  // schemeStart: must begin with an ASCII alpha.
  guard ASCII(input[cursor])?.isAlpha == true else { return nil }
  
  // scheme: allow all ASCII { alphaNumeric, +, -, . } characters.
  cursor = input.index(after: cursor)
  let _schemeEnd = input[cursor...].firstIndex(where: { byte in
    let c = ASCII(byte)
    switch c {
    case _ where c?.isAlphaNumeric == true, .plus?, .minus?, .period?:
      return false
    default:
      // TODO: assert(c != ASCII.horizontalTab && c != ASCII.lineFeed)
      return true
    }
  })
  // schemes end with an ASCII colon.
  guard let schemeEnd = _schemeEnd, input[schemeEnd] == ASCII.colon.codePoint else {
    return nil
  }
  cursor = input.index(after: schemeEnd)
  return cursor
}

func iteratePathComponents<Input>(_ input: Input, schemeIsSpecial: Bool, isFileScheme: Bool, _ block: (Bool, Input.SubSequence)->Void)
  where Input: BidirectionalCollection, Input.Element == UInt8 {
    
    func isPathComponentTerminator(_ byte: UInt8) -> Bool {
      return ASCII(byte) == .forwardSlash || (schemeIsSpecial && ASCII(byte) == .backslash)
    }
    
    guard input.isEmpty == false else {
      if schemeIsSpecial {
        block(true, input.prefix(0))
      }
      return
    }

    var contentStartIdx = input.startIndex
    
    // Drop the initial separator slash if the input includes it.
    if isPathComponentTerminator(input[contentStartIdx]) {
      contentStartIdx = input.index(after: contentStartIdx)
    }
    // For file URLs, also drop any other leading slashes, single- or double-dot path components.
    if isFileScheme {
      while contentStartIdx != input.endIndex, isPathComponentTerminator(input[contentStartIdx]) {
        // callback.validationError(.unexpectedEmptyPath)
        contentStartIdx = input.index(after: contentStartIdx)
      }
      while let terminator = input[contentStartIdx...].firstIndex(where: isPathComponentTerminator) {
        let component = input[contentStartIdx..<terminator]
        guard URLStringUtils.isSingleDotPathSegment(component) || URLStringUtils.isDoubleDotPathSegment(component) else {
          break
        }
        contentStartIdx = input.index(after: terminator)
      }
    }
    
    guard contentStartIdx != input.endIndex else {
      // If the path (after trimming) is empty, we
      block(false, input[contentStartIdx..<contentStartIdx])
      return
    }
    
    // Path component special cases:
    //
    // - Single dot ('.') components get skipped.
    //   - If at the end of the path, they force a trailing slash.
    // - Double dot ('..') components pop previous components from the path.
    //   - For file URLs, they do not pop the last component if it is a Windows drive letter.
    //   - If at the end of the path, they force a trailing slash.
    //     (even if they have popped all other components, the result is an empty path, not a nil path)
    // - Sequential empty components at the start of a file URL get collapsed.
    
    // Iterate the path components in reverse, so we can skip components which later get popped.
    var path = input[contentStartIdx...]
    var popcount = 0
    var trailingEmptyCount = 0
    var didYieldComponent = false
    
    func flushTrailingEmpties() {
      if trailingEmptyCount != 0 {
        for _ in 0 ..< trailingEmptyCount {
          block(false, input.suffix(0))
        }
        didYieldComponent = true
        trailingEmptyCount = 0
      }
    }
        
    // Consume components separated by terminators.
    while let componentTerminatorIndex = path.lastIndex(where: isPathComponentTerminator) {
      // Since we stripped the initial slash, we always have a multi-component path here.
      
      if ASCII(input[componentTerminatorIndex]) == .backslash {
        //callback.validationError(.unexpectedReverseSolidus)
      }
      
      let pathComponent = input[path.index(after: componentTerminatorIndex)..<path.endIndex]
      defer { path = path.prefix(upTo: componentTerminatorIndex) }
 
      // If this is a '..' component, skip it and increase the popcount.
      // If at the end of the path, mark it as a trailing empty.
      guard URLStringUtils.isDoubleDotPathSegment(pathComponent) == false else {
        popcount += 1
        if pathComponent.endIndex == input.endIndex {
					trailingEmptyCount += 1
        }
        continue
      }
      // If the popcount is not 0, this component can be ignored because of a subsequent '..'.
      guard popcount == 0 else {
        popcount -= 1
        continue
      }
			// If this is a '.' component, skip it.
      // If at the end of the path, mark it as a trailing empty.
      if URLStringUtils.isSingleDotPathSegment(pathComponent) {
        if pathComponent.endIndex == input.endIndex {
          trailingEmptyCount += 1
        }
        continue
      }
      // If this component is empty, defer it until we process later components.
      if pathComponent.isEmpty {
        trailingEmptyCount += 1
        continue
      }
      flushTrailingEmpties()
      // FIXME: If we don't strip leading slashes (e.g. for non-file URLs), this may indeed be the first component.
      //        As in, we may never yield another component after this (e.g. "file://C|/").
      //        Luckily this only matters for file URLs, where we *do* strip the leading slashes.
      block(false, pathComponent)
      didYieldComponent = true
    }
    
    print("trailing empties: \(trailingEmptyCount)")
    
    if URLStringUtils.isDoubleDotPathSegment(path) {
      popcount += 1
    }
    
    guard popcount == 0 else {
      // This component has been popped-out.
      
      // If the first path component is a Windows drive letter, it can't be popped-out.
      if isFileScheme, URLStringUtils.isWindowsDriveLetter(path) {
        flushTrailingEmpties()
        block(true, path)
        return
      }
      if !isFileScheme {
        flushTrailingEmpties()
      }
      if didYieldComponent == false {
        block(true, input.prefix(0))
      }
      return
    }

    if URLStringUtils.isSingleDotPathSegment(path) {
      // This is a single-dot component which does not contribute to the final path,
      // other than to force an empty component if no other components were yielded.

      if !isFileScheme {
        flushTrailingEmpties()
      }
      if didYieldComponent == false {
        block(true, input.prefix(0))
      }
      return
    }
        
    if path.isEmpty && isFileScheme {
      // This means we have a leading empty component in a file URL (e.g. "file://somehost//foo/").
      // Discard trailing empties and only yield
      if didYieldComponent == false {
        block(true, path)
      }
      return
    }
    
    flushTrailingEmpties()
    block(true, path)
}


func iterateAppendedPathComponents<Input>(_ input: Input, baseURL: NewURL, schemeIsSpecial: Bool, isFileScheme: Bool, _ realblock: (Bool, AnyBidirectionalCollection<UInt8>)->Void)
  where Input: BidirectionalCollection, Input.Element == UInt8 {
    
    func block<T>(_ isFirst: Bool, _ slice: T) where T: BidirectionalCollection, T.Element == UInt8 {
      realblock(isFirst, AnyBidirectionalCollection(slice))
    }
    func isPathComponentTerminator(_ byte: UInt8) -> Bool {
      return ASCII(byte) == .forwardSlash || (schemeIsSpecial && ASCII(byte) == .backslash)
    }
    
    var contentStartIdx = input.startIndex
    
    // Special URLs have an implicit, empty path.
    guard input.isEmpty == false else {
      if schemeIsSpecial {
        block(true, input[...])
      }
      return
    }

    // Trim leading slash if present.
    if isPathComponentTerminator(input[contentStartIdx]) {
      contentStartIdx = input.index(after: contentStartIdx)
    }
    // File paths trim _all_ leading slashes, single- and double-dot path components.
    if isFileScheme {
      while contentStartIdx != input.endIndex, isPathComponentTerminator(input[contentStartIdx]) {
        // callback.validationError(.unexpectedEmptyPath)
        contentStartIdx = input.index(after: contentStartIdx)
      }
      while let terminator = input[contentStartIdx...].firstIndex(where: isPathComponentTerminator) {
        let component = input[contentStartIdx..<terminator]
        guard URLStringUtils.isSingleDotPathSegment(component) || URLStringUtils.isDoubleDotPathSegment(component) else {
          break
        }
        contentStartIdx = input.index(after: terminator)
      }
    }
    
    // If the path wasn't empty before, but is now, the path is a lone slash (non-file) or string of slashes (file).
    // A path of "/" always resolves to "/", and is not relative to the base path...
    //  - Except: if this is a file URL and the base path starts with a Windows drive letter (X). Then the resolved path is just "X:/"
    guard contentStartIdx != input.endIndex else {
      assert(isFileScheme, "Only file URLs seem to hit this path")
      
      var didYield = false
      if isFileScheme {
        baseURL.withComponentBytes(.path) {
          guard let basePath = $0?.dropFirst() else { return } // dropFirst() due to the leading slash.
          if URLStringUtils.hasWindowsDriveLetterPrefix(basePath) {
            block(false, input[contentStartIdx..<contentStartIdx])
            block(true, basePath.prefix(2))
            didYield = true
          }
        }
      }
      if !didYield {
        block(true, input[contentStartIdx..<contentStartIdx])
      }
      return
    }
    
    // Path component special cases:
    //
    // - Single dot ('.') components get skipped.
    //   - If at the end of the path, they force a trailing slash.
    // - Double dot ('..') components pop previous components from the path.
    //   - For file URLs, they do not pop the last component if it is a Windows drive letter.
    //   - If at the end of the path, they force a trailing slash.
    //     (even if they have popped all other components, the result is an empty path, not a nil path)
    // - Consecutive empty components at the start of a file URL get collapsed.
    
    // Iterate the path components in reverse, so we can skip components which later get popped.
    var path = input[contentStartIdx...]
    var popcount = 0
    var trailingEmptyCount = 0
    var didYieldComponent = false
    
    func flushTrailingEmpties() {
      if trailingEmptyCount != 0 {
        for _ in 0 ..< trailingEmptyCount {
          block(false, input.suffix(0))
        }
        didYieldComponent = true
        trailingEmptyCount = 0
      }
    }
        
    // Consume components separated by terminators.
    while let componentTerminatorIndex = path.lastIndex(where: isPathComponentTerminator) {
      // Since we stripped the initial slash, we always have a multi-component path here.
      
      if ASCII(input[componentTerminatorIndex]) == .backslash {
        //callback.validationError(.unexpectedReverseSolidus)
      }
      
      let pathComponent = input[path.index(after: componentTerminatorIndex)..<path.endIndex]
      defer { path = path.prefix(upTo: componentTerminatorIndex) }
 
      // If this is a '..' component, skip it and increase the popcount.
      // If at the end of the path, mark it as a trailing empty.
      guard URLStringUtils.isDoubleDotPathSegment(pathComponent) == false else {
        popcount += 1
        if pathComponent.endIndex == input.endIndex {
          // FIXME: Never executed in tests.
          trailingEmptyCount += 1
        }
        continue
      }
      // If the popcount is not 0, this component can be ignored because of a subsequent '..'.
      guard popcount == 0 else {
        popcount -= 1
        continue
      }
      // If this is a '.' component, skip it.
      // If at the end of the path, mark it as a trailing empty.
      if URLStringUtils.isSingleDotPathSegment(pathComponent) {
        if pathComponent.endIndex == input.endIndex {
          trailingEmptyCount += 1
        }
        continue
      }
      // If this component is empty, defer it until we process later components.
      if pathComponent.isEmpty {
        trailingEmptyCount += 1
        continue
      }
      flushTrailingEmpties()
      // FIXME: If we don't strip leading slashes (e.g. for non-file URLs), this may indeed be the first component.
      //        As in, we may never yield another component after this (e.g. "file://C|/").
      //        Luckily this only matters for file URLs, where we *do* strip the leading slashes.
      block(false, pathComponent)
      didYieldComponent = true
    }
    
    assert(path.isEmpty == false)
    print("Input string trailing empties: \(trailingEmptyCount)")
    
    switch path {
    // Process '..' and '.'. If this is the first component, ensure we have a trailing slash.
    case _ where URLStringUtils.isDoubleDotPathSegment(path):
      popcount += 1
      fallthrough
    case _ where URLStringUtils.isSingleDotPathSegment(path):
      if !didYieldComponent {
        trailingEmptyCount = max(trailingEmptyCount, 1)
      }
      
    // If the first path component is a Windows drive letter, it can't be popped-out,
    // and we don't care about the base URL.
    case _ where URLStringUtils.isWindowsDriveLetter(path) && isFileScheme:
      flushTrailingEmpties()
      block(true, path)
      return

    case _ where popcount == 0:
    	flushTrailingEmpties()
      block(true, path) // FIXME: May not actually be the first component.
      didYieldComponent = true
      
    default:
      popcount -= 1
      break // Popped out.
    }
    
    // Okay, let's check out the base path now.
    baseURL.withComponentBytes(.path) {
      guard var basePath = $0?[...] else {
        return
      }
      // Trim the leading slash.
      if basePath.first == ASCII.forwardSlash.codePoint {
        basePath = basePath.dropFirst()
      }
      // Drop the last path component.y
      if basePath.last == ASCII.forwardSlash.codePoint {
        basePath = basePath.dropLast()
      } else {
       	basePath = basePath[..<(basePath.lastIndex(of: ASCII.forwardSlash.codePoint) ?? basePath.startIndex)]
      }
      // Consume all other components. Process them like we do for the input string.
      while let componentTerminatorIndex = basePath.lastIndex(of: ASCII.forwardSlash.codePoint) {
        let pathComponent = basePath[basePath.index(after: componentTerminatorIndex)..<basePath.endIndex]
        defer { basePath = basePath.prefix(upTo: componentTerminatorIndex) }
        
        assert(URLStringUtils.isDoubleDotPathSegment(pathComponent) == false)
        assert(URLStringUtils.isSingleDotPathSegment(pathComponent) == false)
        // If the popcount is not 0, this component can be ignored because of a subsequent '..'.
        guard popcount == 0 else {
          popcount -= 1
          continue
        }
        // If this component is empty, defer it until we process later components.
        if pathComponent.isEmpty {
          trailingEmptyCount += 1
          continue
        }
        flushTrailingEmpties()
        block(false, pathComponent)
        didYieldComponent = true
      }
      
      guard popcount == 0 else {
        // This component has been popped-out.
        
        // If the first path component is a Windows drive letter, it can't be popped-out.
        if isFileScheme, URLStringUtils.isWindowsDriveLetter(basePath) {
          trailingEmptyCount = max(1, trailingEmptyCount)
          flushTrailingEmpties()
          block(true, basePath)
          return
        }
        if !isFileScheme {
          flushTrailingEmpties()
        }
        if didYieldComponent == false {
          block(true, input.prefix(0))
        }
        return
      }
      
      assert(URLStringUtils.isDoubleDotPathSegment(basePath) == false)
      assert(URLStringUtils.isSingleDotPathSegment(basePath) == false)
      
      if basePath.isEmpty {
        if !isFileScheme {
          flushTrailingEmpties()
        }
        // This means we have a leading empty component in a file URL (e.g. "file://somehost//foo/").
        // Discard trailing empties and only yield
        if didYieldComponent == false {
          // FIXME: Never executed in tests.
          block(true, basePath)
        }
        return
      }
      
      flushTrailingEmpties()
      block(true, basePath)
    }
}

struct URLScanner<Input, T, Callback> where Input: BidirectionalCollection, Input.Element == UInt8, Input.SubSequence == Input,
Mapping<T>.Index == Input.Index, Callback: URLParserCallback {
  
  enum ComponentParseResult {
    case failed
    case success(continueFrom: (ParsableComponent, Input.Index)?)
  }
  
  typealias Scheme = NewURLParser.Scheme
}

// URLs with schemes.
// ------------------
// Broadly, the pattern is to look for an authority (host, etc), then path, query and fragment.

extension URLScanner {
  
  /// Scans all components of the input string `input`, and builds up a map based on the URL's `scheme`.
  ///
  static func scanURLWithScheme(_ input: Input, scheme: NewURLParser.Scheme, baseURL: NewURL?, _ mapping: inout Mapping<T>,
                                callback: inout Callback) -> Bool {

    switch scheme {
    case .file:
      if !URLStringUtils.hasDoubleSolidusPrefix(input) {
      	callback.validationError(.fileSchemeMissingFollowingSolidus)
      }
      return scanAllFileURLComponents(input, baseURL: baseURL, &mapping, callback: &callback)
      
    case .other: // non-special.
      let firstIndex = input.startIndex
      guard firstIndex != input.endIndex, ASCII(input[firstIndex]) == .forwardSlash else {
        mapping.cannotBeABaseURL = true
        return scanAllCannotBeABaseURLComponents(input, scheme: scheme, &mapping, callback: &callback)
      }
      // state: "path or authority"
      let secondIndex = input.index(after: firstIndex)
      if secondIndex != input.endIndex, ASCII(input[secondIndex]) == .forwardSlash {
        let authorityStart = input.index(after: secondIndex)
        return scanAllComponents(from: .authority, input[authorityStart...], scheme: scheme, &mapping, callback: &callback)
      } else {
        return scanAllComponents(from: .path, input[firstIndex...], scheme: scheme, &mapping, callback: &callback)
      }
        
    // !!!! FIXME: We actually need to check that the *content* of `scheme` is the same as `baseURLScheme` !!!!
      
    default: // special schemes other than 'file'.
      if scheme == baseURL?.schemeKind, URLStringUtils.hasDoubleSolidusPrefix(input) == false {
        // state: "special relative or authority"
        callback.validationError(.relativeURLMissingBeginningSolidus)
        return scanAllRelativeURLComponents(input, baseScheme: scheme, &mapping, callback: &callback)
      }
      // state: "special authority slashes"
      var authorityStart = input.startIndex
      if URLStringUtils.hasDoubleSolidusPrefix(input) {
        authorityStart = input.index(authorityStart, offsetBy: 2)
      } else {
        callback.validationError(.missingSolidusBeforeAuthority)
      }
      // state: "special authority ignore slashes"
      authorityStart = input[authorityStart...].drop { ASCII($0) == .forwardSlash || ASCII($0) == .backslash }.startIndex
      return scanAllComponents(from: .authority, input[authorityStart...], scheme: scheme, &mapping, callback: &callback)
    }
  }
  
  /// Scans the given component from `input`, and continues scanning additional components until we can't find any more.
  ///
  static func scanAllComponents(from: ParsableComponent, _ input: Input, scheme: NewURLParser.Scheme, _ mapping: inout Mapping<T>,
                                callback: inout Callback) -> Bool {
    var component = from
    var remaining = input[...]
    while true {
      print("** Parsing component: \(component)")
      print("** Data: \(String(decoding: remaining, as: UTF8.self))")
      let componentResult: ComponentParseResult
      switch component {
      case .authority:
        componentResult = scanAuthority(remaining, scheme: scheme, &mapping, callback: &callback)
      case .pathStart:
        componentResult = scanPathStart(remaining, scheme: scheme, &mapping, callback: &callback)
      case .path:
        componentResult = scanPath(remaining, scheme: scheme, &mapping, callback: &callback)
      case .query:
        componentResult = scanQuery(remaining, scheme: scheme, &mapping, callback: &callback)
      case .fragment:
        componentResult = scanFragment(remaining, &mapping, callback: &callback)
      case .scheme:
          fatalError()
      case .host:
        fatalError()
      case .port:
        fatalError()
      }
      guard case .success(let _nextComponent) = componentResult else {
        return false
      }
      guard let nextComponent = _nextComponent else {
        break
      }
      component = nextComponent.0
      remaining = remaining[nextComponent.1...]
    }
    return true
  }
  
  /// Scans the "authority" component of a URL, containing:
  ///  - Username
  ///  - Password
  ///  - Host
  ///  - Port
  ///
  ///  If parsing doesn't fail, the next component is always `pathStart`.
  ///
  static func scanAuthority(_ input: Input, scheme: NewURLParser.Scheme,_ mapping: inout Mapping<T>, callback: inout Callback) -> ComponentParseResult {
     
    // 1. Validate the mapping.
    assert(mapping.usernameEndIndex.get() == nil)
    assert(mapping.passwordEndIndex.get() == nil)
    assert(mapping.hostnameEndIndex.get() == nil)
    assert(mapping.portEndIndex.get() == nil)
    assert(mapping.path.get() == nil)
    assert(mapping.query.get() == nil)
    assert(mapping.fragment.get() == nil)
    
    // 2. Find the extent of the authority (i.e. the terminator between host and path/query/fragment).
    let authority = input.prefix {
      switch ASCII($0) {
      case ASCII.forwardSlash?, ASCII.questionMark?, ASCII.numberSign?:
        return false
      case ASCII.backslash? where scheme.isSpecial:
        return false
      default:
        return true
     }
    }
    mapping.authorityStartPosition.set(to: authority.startIndex)

    var hostStartIndex = authority.startIndex
    
    // 3. Find the extent of the credentials, if there are any.
    if let credentialsEndIndex = authority.lastIndex(where: { ASCII($0) == .commercialAt }) {
      hostStartIndex = input.index(after: credentialsEndIndex)
      callback.validationError(.unexpectedCommercialAt)
      guard hostStartIndex != authority.endIndex else {
        callback.validationError(.unexpectedCredentialsWithoutHost)
        return .failed
      }

      let credentials = authority[..<credentialsEndIndex]
      let username = credentials.prefix { ASCII($0) != .colon }
      mapping.usernameEndIndex.set(to: username.endIndex)
      if username.endIndex != credentials.endIndex {
        mapping.passwordEndIndex.set(to: credentials.endIndex)
      }
    }
    
    // 3. Scan the host/port and propagate the continutation advice.
    let hostname = authority[hostStartIndex...]
    guard hostname.isEmpty == false else {
      if scheme.isSpecial {
        callback.validationError(.emptyHostSpecialScheme)
        return .failed
      }
      mapping.hostnameEndIndex.set(to: hostStartIndex)
      return .success(continueFrom: (.pathStart, hostStartIndex))
    }
    
    guard case .success(let postHost) = scanHostname(hostname, scheme: scheme, &mapping, callback: &callback) else {
      return .failed
    }
    // Scan the port, if the host requested it.
    guard let portComponent = postHost, case .port = portComponent.0 else {
      return .success(continueFrom: postHost)
    }
    guard case .success(let postPort) = scanPort(authority[portComponent.1...], scheme: scheme, &mapping, callback: &callback) else {
      return .failed
    }
    return .success(continueFrom: postPort)
  }
  
  static func scanHostname(_ input: Input, scheme: Scheme, _ mapping: inout Mapping<T>, callback: inout Callback) -> ComponentParseResult {
    
    // 1. Validate the mapping.
    assert(mapping.hostnameEndIndex.get() == nil)
    assert(mapping.portEndIndex.get() == nil)
    assert(mapping.path.get() == nil)
    assert(mapping.query.get() == nil)
    assert(mapping.fragment.get() == nil)
    
    // 2. Find the extent of the hostname.
    var hostnameEndIndex: Input.Index?
    var inBracket = false
    colonSearch: for idx in input.indices {
      switch ASCII(input[idx]) {
      case .leftSquareBracket?:
        inBracket = true
      case .rightSquareBracket?:
        inBracket = false
      case .colon? where inBracket == false:
        hostnameEndIndex = idx
        break colonSearch
      default:
        break
      }
    }
    let hostname = input[..<(hostnameEndIndex ?? input.endIndex)]
    
    // 3. Validate the hostname.
    if let portStartIndex = hostnameEndIndex, portStartIndex == input.startIndex {
      callback.validationError(.unexpectedPortWithoutHost)
      return .failed
    }
    // swift-format-ignore
    guard let _ = Array(hostname).withUnsafeBufferPointer({ buffer -> WebURLParser.Host? in
      return WebURLParser.Host.parse(buffer, isNotSpecial: scheme.isSpecial == false, callback: &callback)
    }) else {
      return .failed
    }
    
    // 4. Return the next component.
    mapping.hostnameEndIndex.set(to: hostname.endIndex)
    if let hostnameEnd = hostnameEndIndex {
      return .success(continueFrom: (.port, input.index(after: hostnameEnd)))
    } else {
      return .success(continueFrom: (.pathStart, input.endIndex))
    }
  }
  
  static func scanPort(_ input: Input, scheme: Scheme, _ mapping: inout Mapping<T>, callback: inout Callback) -> ComponentParseResult {
    
    // 1. Validate the mapping.
    assert(mapping.portEndIndex.get() == nil)
    assert(mapping.path.get() == nil)
    assert(mapping.query.get() == nil)
    assert(mapping.fragment.get() == nil)
    
    // 2. Find the extent of the port string.
    let portString = input.prefix { ASCII($0).map { ASCII.ranges.digits.contains($0) } ?? false }
    
    // 3. Validate the port string.
    // The only thing allowed after the numbers is an authority terminator character.
    if portString.endIndex != input.endIndex {
      switch ASCII(input[portString.endIndex]) {
      case .forwardSlash?, .questionMark?, .numberSign?:
        break
      case .backslash? where scheme.isSpecial:
        break
      default:
        callback.validationError(.portInvalid)
        return .failed
      }
    }
 
    // 4. Return the next component.
    mapping.portEndIndex.set(to: portString.endIndex)
    return .success(continueFrom: (.pathStart, portString.endIndex))
  }

  /// Scans the URL string from the character immediately following the authority, and advises
  /// whether the remainder is a path, query or fragment.
  ///
  static func scanPathStart(_ input: Input, scheme: Scheme, _ mapping: inout Mapping<T>, callback: inout Callback) -> ComponentParseResult {
      
    // 1. Validate the mapping.
    assert(mapping.path.get() == nil)
    assert(mapping.query.get() == nil)
    assert(mapping.fragment.get() == nil)
    
    // 2. Return the component to parse based on input.
    guard input.isEmpty == false else {
      return .success(continueFrom: (.path, input.startIndex))
    }
    
    let c: ASCII? = ASCII(input[input.startIndex])
    switch c {
    case .questionMark?:
      return .success(continueFrom: (.query, input.index(after: input.startIndex)))
      
    case .numberSign?:
      return .success(continueFrom: (.fragment, input.index(after: input.startIndex)))
      
    default:
      return .success(continueFrom: (.path, input.startIndex))
    }
  }
  
  // Note: This considers the percent sign ("%") a valid URL code-point.
  //
  static func validateURLCodePointsAndPercentEncoding(_ input: Input, callback: inout Callback) {
    
    if URLStringUtils.hasNonURLCodePoints(input, allowPercentSign: true) {
      callback.validationError(.invalidURLCodePoint)
    }
    
    var percentSignSearchIdx = input.startIndex
    while let percentSignIdx = input[percentSignSearchIdx...].firstIndex(where: { ASCII($0) == .percentSign }) {
      percentSignSearchIdx = input.index(after: percentSignIdx)
      let nextTwo = input[percentSignIdx...].prefix(2)
      if nextTwo.count != 2 || !nextTwo.allSatisfy({ ASCII($0)?.isHexDigit ?? false }) {
        callback.validationError(.unescapedPercentSign)
      }
    }
  }

  /// Scans a URL path string from the given input, and advises whether there are any components following it.
  ///
  static func scanPath(_ input: Input, scheme: Scheme, _ mapping: inout Mapping<T>, callback: inout Callback) -> ComponentParseResult {
    
    // 1. Validate the mapping.
    assert(mapping.path.get() == nil)
    assert(mapping.query.get() == nil)
    assert(mapping.fragment.get() == nil)
    
    // 2. Find the extent of the path.
    let nextComponentStartIndex = input.firstIndex { ASCII($0) == .questionMark || ASCII($0) == .numberSign }
    let path = input[..<(nextComponentStartIndex ?? input.endIndex)]

    // 3. Validate the path's contents.
    iteratePathComponents(path, schemeIsSpecial: scheme.isSpecial, isFileScheme: scheme == .file) { _, pathComponent in
      if pathComponent.endIndex != path.endIndex, ASCII(path[pathComponent.endIndex]) == .backslash {
        callback.validationError(.unexpectedReverseSolidus)
      }
      validateURLCodePointsAndPercentEncoding(pathComponent, callback: &callback)
      print("path component: \(String(decoding: pathComponent, as: UTF8.self))")
    }
      
    // 4. Return the next component.
    if path.isEmpty && scheme.isSpecial == false {
       mapping.path.set(to: nil)
    } else {
      mapping.path.set(to: path.endIndex)
    }
    if let pathEnd = nextComponentStartIndex {
      return .success(continueFrom: (ASCII(input[pathEnd]) == .questionMark ? .query : .fragment,
                                     input.index(after: pathEnd)))
    } else {
      return .success(continueFrom: nil)
    }
  }
  
  /// Scans a URL query string from the given input, and advises whether there are any components following it.
  ///
  static func scanQuery(_ input: Input, scheme: Scheme, _ mapping: inout Mapping<T>, callback: inout Callback) -> ComponentParseResult {
    
    // 1. Validate the mapping.
    assert(mapping.query.get() == nil)
    assert(mapping.fragment.get() == nil)
    
    // 2. Find the extent of the query
    let queryEndIndex = input.firstIndex { ASCII($0) == .numberSign }
      
    // 3. Validate the query-string.
    validateURLCodePointsAndPercentEncoding(input.prefix(upTo: queryEndIndex ?? input.endIndex), callback: &callback)
      
    // 3. Return the next component.
    mapping.query.set(to: queryEndIndex ?? input.endIndex)
    if let queryEnd = queryEndIndex {
      return .success(continueFrom: ASCII(input[queryEnd]) == .numberSign ? (.fragment, input.index(after: queryEnd)) : nil)
    } else {
      return .success(continueFrom: nil)
    }
  }
  
  /// Scans a URL fragment string from the given input. There are never any components following it.
  ///
  static func scanFragment(_ input: Input, _ mapping: inout Mapping<T>, callback: inout Callback) -> ComponentParseResult {
    
    // 1. Validate the mapping.
    assert(mapping.fragment.get() == nil)
    
    // 2. Validate the fragment string.
    validateURLCodePointsAndPercentEncoding(input, callback: &callback)
    
    mapping.fragment.set(to: input.endIndex)
    return .success(continueFrom: nil)
  }
}

// File URLs.
// ---------

extension URLScanner {
  
  /// Scans the given component from `input`, and continues scanning additional components until we can't find any more.
  ///
  static func scanAllFileURLComponents(_ input: Input, baseURL: NewURL?, _ mapping: inout Mapping<T>, callback: inout Callback) -> Bool {
    var remaining = input[...]
    
    guard case .success(let _component) = parseFileURLStart(remaining, baseURL: baseURL, &mapping, callback: &callback) else {
      return false
    }
    guard var component = _component else {
      return true
    }
    remaining = input.suffix(from: component.1)
    while true {
      print("** [FILEURL] Parsing component: \(component)")
      print("** [FILEURL] Data: \(String(decoding: remaining, as: UTF8.self))")
      let componentResult: ComponentParseResult
      switch component.0 {
      case .authority:
        componentResult = scanAuthority(remaining, scheme: .file, &mapping, callback: &callback)
      case .pathStart:
        componentResult = scanPathStart(remaining, scheme: .file, &mapping, callback: &callback)
      case .path:
        componentResult = scanPath(remaining, scheme: .file, &mapping, callback: &callback)
      case .query:
        componentResult = scanQuery(remaining, scheme: .file, &mapping, callback: &callback)
      case .fragment:
        componentResult = scanFragment(remaining, &mapping, callback: &callback)
      case .scheme:
          fatalError()
      case .host:
        fatalError()
      case .port:
        fatalError()
      }
      guard case .success(let _nextComponent) = componentResult else {
        return false
      }
      guard let nextComponent = _nextComponent else {
        break
      }
      component = nextComponent
      remaining = remaining.suffix(from: component.1)
    }
    return true
  }
  
  static func parseFileURLStart(_ input: Input, baseURL: NewURL?, _ mapping: inout Mapping<T>, callback: inout Callback) -> ComponentParseResult {
    
    // Note that file URLs may also be relative URLs. It all depends on what comes after "file:".
    // - 0 slashes:  copy base host, parse as path relative to base path.
    // - 1 slash:    copy base host, parse as absolute path.
    // - 2 slashes:  parse own host, parse absolute path.
    // - 3 slahses:  empty host, parse as absolute path.
    // - 4+ slashes: invalid.
    
    let baseScheme = baseURL?.schemeKind
    
    var cursor = input.startIndex
    guard cursor != input.endIndex, let c0 = ASCII(input[cursor]), (c0 == .forwardSlash || c0 == .backslash) else {
      // No slashes. May be a relative path ("file:usr/lib/Swift") or no path ("file:?someQuery").
      guard baseScheme == .file else {
        return .success(continueFrom: (.path, cursor))
      }
      assert(mapping.componentsToCopyFromBase.isEmpty || mapping.componentsToCopyFromBase == [.scheme])
      mapping.componentsToCopyFromBase.formUnion([.authority, .path, .query])

      guard cursor != input.endIndex else {
        return .success(continueFrom: nil)
      }
      switch ASCII(input[cursor]) {
      case .questionMark?:
        mapping.componentsToCopyFromBase.remove(.query)
        return .success(continueFrom: (.query, input.index(after: cursor)))
      case .numberSign?:
        return .success(continueFrom: (.fragment, input.index(after: cursor)))
      default:
        if URLStringUtils.hasWindowsDriveLetterPrefix(input[cursor...]) {
          callback.validationError(.unexpectedWindowsDriveLetter)
        }
        return .success(continueFrom: (.path, cursor))
      }
    }
    cursor = input.index(after: cursor)
    if c0 == .backslash {
      callback.validationError(.unexpectedReverseSolidus)
    }
    
    guard cursor != input.endIndex, let c1 = ASCII(input[cursor]), (c1 == .forwardSlash || c1 == .backslash) else {
      // 1 slash. e.g. "file:/usr/lib/Swift". Absolute path.
      
      if baseScheme == .file, URLStringUtils.hasWindowsDriveLetterPrefix(input[cursor...]) == false {
        // This string does not begin with a Windows drive letter.
        // If baseURL's path *does*, we are relative to it, rather than being absolute.
        // The appended-path-iteration function handles this case for us, which we opt-in to
        // by having a non-empty path in a special-scheme URL (meaning a guaranteed non-nil path) and
        // including 'path' in 'componentsToCopyFromBase'.
        let basePathStartsWithWindowsDriveLetter: Bool = baseURL.map {
          $0.withComponentBytes(.path) {
            guard let basePath = $0 else { return false }
            return URLStringUtils.hasWindowsDriveLetterPrefix(basePath.dropFirst())
          }
        } ?? false
        if basePathStartsWithWindowsDriveLetter {
          mapping.componentsToCopyFromBase.formUnion([.path])
        } else {
          // No Windows drive letters anywhere. Copy the host and parse our path normally.
          mapping.componentsToCopyFromBase.formUnion([.authority])
        }
      }
      return scanPath(input, scheme: .file, &mapping, callback: &callback)
    }
    
    cursor = input.index(after: cursor)
    if c1 == .backslash {
      callback.validationError(.unexpectedReverseSolidus)
    }
    
    // 2+ slashes. e.g. "file://localhost/usr/lib/Swift" or "file:///usr/lib/Swift".
    return scanFileHost(input[cursor...], &mapping, callback: &callback)
  }
  
  
  static func scanFileHost(_ input: Input, _ mapping: inout Mapping<T>, callback: inout Callback) -> ComponentParseResult {
   
    // 1. Validate the mapping.
    assert(mapping.authorityStartPosition.get() == nil)
    assert(mapping.hostnameEndIndex.get() == nil)
    assert(mapping.portEndIndex.get() == nil)
    assert(mapping.path.get() == nil)
    assert(mapping.query.get() == nil)
    assert(mapping.fragment.get() == nil)
    
    // 2. Find the extent of the hostname.
    let hostnameEndIndex = input.firstIndex { byte in
      switch ASCII(byte) {
      case .forwardSlash?, .backslash?, .questionMark?, .numberSign?: return true
      default: return false
      }
    } ?? input.endIndex
    
    let hostname = input[..<hostnameEndIndex]
    
    // 3. Validate the hostname.
    if URLStringUtils.isWindowsDriveLetter(hostname) {
      // TODO: Only if not in setter-mode.
      callback.validationError(.unexpectedWindowsDriveLetterHost)
      return .success(continueFrom: (.path, input.startIndex))
    }
    if hostname.isEmpty {
      return .success(continueFrom: (.pathStart, input.startIndex))
    }
    // swift-format-ignore
    guard let parsedHost = Array(hostname).withUnsafeBufferPointer({ buffer -> WebURLParser.Host? in
      return WebURLParser.Host.parse(buffer, isNotSpecial: false, callback: &callback)
    }) else {
      return .failed
    }
    
    // 4. Return the next component.
    mapping.authorityStartPosition.set(to: input.startIndex)
    mapping.hostnameEndIndex.set(to: hostnameEndIndex)
    return .success(continueFrom: (.pathStart, hostnameEndIndex))
  }
}

// "cannot-base-a-base" URLs.
// --------------------------

extension URLScanner {
  
  /// Scans the given component from `input`, and continues scanning additional components until we can't find any more.
    ///
    static func scanAllCannotBeABaseURLComponents(_ input: Input, scheme: NewURLParser.Scheme, _ mapping: inout Mapping<T>, callback: inout Callback) -> Bool {
      var remaining = input[...]
      
      guard case .success(let _component) = scanCannotBeABaseURLPath(remaining, &mapping, callback: &callback) else {
        return false
      }
      guard var component = _component else {
        return true
      }
      remaining = input.suffix(from: component.1)
      while true {
        print("** [CANNOTBEABASE URL] Parsing component: \(component)")
        print("** [CANNOTBEABASE URL] Data: \(String(decoding: remaining, as: UTF8.self))")
        let componentResult: ComponentParseResult
        switch component.0 {
        case .query:
          componentResult = scanQuery(remaining, scheme: scheme, &mapping, callback: &callback)
        case .fragment:
          componentResult = scanFragment(remaining, &mapping, callback: &callback)
        case .path:
          fatalError()
        case .pathStart:
          fatalError()
        case .authority:
          fatalError()
        case .scheme:
          fatalError()
        case .host:
          fatalError()
        case .port:
          fatalError()
        }
        guard case .success(let _nextComponent) = componentResult else {
          return false
        }
        guard let nextComponent = _nextComponent else {
          break
        }
        component = nextComponent
        remaining = remaining.suffix(from: component.1)
      }
      return true
    }

  static func scanCannotBeABaseURLPath(_ input: Input, _ mapping: inout Mapping<T>, callback: inout Callback) -> ComponentParseResult {
    
    // 1. Validate the mapping.
    assert(mapping.authorityStartPosition.get() == nil)
    assert(mapping.hostnameEndIndex.get() == nil)
    assert(mapping.portEndIndex.get() == nil)
    assert(mapping.path.get() == nil)
    assert(mapping.query.get() == nil)
    assert(mapping.fragment.get() == nil)
    
    // 2. Find the extent of the path.
    let pathEndIndex = input.firstIndex { byte in
      switch ASCII(byte) {
      case .questionMark?, .numberSign?: return true
      default: return false
      }
    }
    let path = input[..<(pathEndIndex ?? input.endIndex)]
    
    // 3. Validate the path.
    validateURLCodePointsAndPercentEncoding(path, callback: &callback)
        
    // 4. Return the next component.
    if let pathEnd = pathEndIndex {
      mapping.path.set(to: pathEnd)
      return .success(continueFrom: (ASCII(input[pathEnd]) == .questionMark ? .query : .fragment,
                                     input.index(after: pathEnd)))
    } else {
      mapping.path.set(to: path.isEmpty ? nil : input.endIndex)
      return .success(continueFrom: nil)
    }
  }
}

// Relative URLs.
// --------------

extension URLScanner {
  
  /// Scans the given component from `input`, and continues scanning additional components until we can't find any more.
  ///
  static func scanAllRelativeURLComponents(_ input: Input, baseScheme: NewURLParser.Scheme, _ mapping: inout Mapping<T>, callback: inout Callback) -> Bool {
    var remaining = input[...]
    
    guard case .success(let _component) = parseRelativeURLStart(remaining, baseScheme: baseScheme, &mapping, callback: &callback) else {
      return false
    }
    guard var component = _component else {
      return true
    }
    remaining = input.suffix(from: component.1)
    while true {
      print("** [RELATIVE URL] Parsing component: \(component)")
      print("** [RELATIVE URL] Data: \(String(decoding: remaining, as: UTF8.self))")
      let componentResult: ComponentParseResult
      switch component.0 {
      case .path:
        componentResult = scanPath(remaining, scheme: baseScheme, &mapping, callback: &callback)
      case .query:
        componentResult = scanQuery(remaining, scheme: baseScheme, &mapping, callback: &callback)
      case .fragment:
        componentResult = scanFragment(remaining, &mapping, callback: &callback)
      case .pathStart:
        componentResult = scanPathStart(remaining, scheme: baseScheme, &mapping, callback: &callback)
      case .authority:
        componentResult = scanAuthority(remaining, scheme: baseScheme, &mapping, callback: &callback)
      case .scheme:
        fatalError()
      case .host:
        fatalError()
      case .port:
        fatalError()
      }
      guard case .success(let _nextComponent) = componentResult else {
        return false
      }
      guard let nextComponent = _nextComponent else {
        break
      }
      component = nextComponent
      remaining = remaining.suffix(from: component.1)
    }
    return true
  }
  
  static func parseRelativeURLStart(_ input: Input, baseScheme: NewURLParser.Scheme, _ mapping: inout Mapping<T>, callback: inout Callback) -> ComponentParseResult {
    print("Reached relative URL")
    
    mapping.componentsToCopyFromBase = [.scheme]
    
    guard input.isEmpty == false else {
      mapping.componentsToCopyFromBase.formUnion([.authority, .path, .query])
      return .success(continueFrom: nil)
    }
    
    switch ASCII(input[input.startIndex]) {
    // Initial slash. Inspect the rest and parse as either a path or authority.
    case .backslash? where baseScheme.isSpecial:
      callback.validationError(.unexpectedReverseSolidus)
      fallthrough
    case .forwardSlash?:
      var cursor = input.index(after: input.startIndex)
      guard cursor != input.endIndex else {
        mapping.componentsToCopyFromBase.formUnion([.authority])
        return .success(continueFrom: (.path, input.startIndex))
      }
      switch ASCII(input[cursor]) {
      // Second character is also a slash. Parse as an authority.
      case .backslash? where baseScheme.isSpecial:
        callback.validationError(.unexpectedReverseSolidus)
        fallthrough
      case .forwardSlash?:
        if baseScheme.isSpecial {
          cursor = input[cursor...].dropFirst().drop { ASCII($0) == .forwardSlash || ASCII($0) == .backslash }.startIndex
        } else {
          cursor = input.index(after: cursor)
        }
        return .success(continueFrom: (.authority, cursor))
      // Otherwise, copy the base authority. Parse as a (absolute) path.
      default:
        mapping.componentsToCopyFromBase.formUnion([.authority])
        return .success(continueFrom: (.path, input.startIndex))
      }
    
    // Initial query/fragment markers.
    case .questionMark?:
      mapping.componentsToCopyFromBase.formUnion([.authority, .path])
      return .success(continueFrom: (.query, input.index(after: input.startIndex)))
    case .numberSign?:
      mapping.componentsToCopyFromBase.formUnion([.authority, .path, .query])
      return .success(continueFrom: (.fragment, input.index(after: input.startIndex)))
      
    // Some other character. Parse as a relative path.
    default:
      // Since we have a non-empty input string with characters before any query/fragment terminators,
      // path-scanning will always produce a mapping with a non-nil pathLength.
      // Construction knows that if a path is found in the input string *and* we ask to copy from the base,
      // that the paths should be combined by stripping the base's last path component.
      mapping.componentsToCopyFromBase.formUnion([.authority, .path])
      return .success(continueFrom: (.path, input.startIndex))
    }
  }
}














