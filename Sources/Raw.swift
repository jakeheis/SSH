import Foundation
import CSSH
import Socket

public enum LibSSH2Error: Swift.Error {
    case error(Int32)
    case initializationError
    
    static func check(code: Int32) throws {
        if code != 0 {
            throw LibSSH2Error.error(code)
        }
    }
}

class RawSession {
    
    private static let initResult = libssh2_init(0)
    
    fileprivate let cSession: OpaquePointer
    
    var rawAgent: RawAgent?
    
    var blocking: Int32 {
        get {
            return libssh2_session_get_blocking(cSession)
        }
        set(newValue) {
            libssh2_session_set_blocking(cSession, newValue)
        }
    }
    
    init() throws {
        try LibSSH2Error.check(code: RawSession.initResult)
        
        guard let cSession = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw LibSSH2Error.initializationError
        }
        
        self.cSession = cSession
    }
    
    func handshake(over socket: Socket) throws {
        let code = libssh2_session_handshake(cSession, socket.socketfd)
        try LibSSH2Error.check(code: code)
    }
    
    func authenticate(username: String, privateKey: String, publicKey: String, passphrase: String?) throws {
        let code = libssh2_userauth_publickey_fromfile_ex(cSession,
                                                          username,
                                                          UInt32(username.characters.count),
                                                          publicKey,
                                                          privateKey,
                                                          passphrase)
        try LibSSH2Error.check(code: code)
    }
    
    func authenticate(username: String, password: String) throws {
        let code = libssh2_userauth_password_ex(cSession,
                                                username,
                                                UInt32(username.characters.count),
                                                password,
                                                UInt32(password.characters.count),
                                                nil)
        try LibSSH2Error.check(code: code)
    }
    
    func openChannel() throws -> RawChannel {
        return try RawChannel(rawSession: self)
    }
    
    func agent() throws -> RawAgent {
        if let rawAgent = rawAgent {
            return rawAgent
        }
        let newAgent = try RawAgent(rawSession: self)
        rawAgent = newAgent
        return newAgent
    }
    
    deinit {
        libssh2_session_free(cSession)
    }
    
}

class RawChannel {
    
    private static let session = "session"
    private static let exec = "exec"
    
    private static let windowDefault: UInt32 = 2 * 1024 * 1024
    private static let packetDefault: UInt32 = 32768
    private static let bufferSize = 0x4000
    
    private let cChannel: OpaquePointer
    
    init(rawSession: RawSession) throws {
        guard let cChannel = libssh2_channel_open_ex(rawSession.cSession,
                                                     RawChannel.session,
                                                     UInt32(RawChannel.session.characters.count),
                                                     RawChannel.windowDefault,
                                                     RawChannel.packetDefault, nil, 0) else {
                                                        throw LibSSH2Error.initializationError
        }
        self.cChannel = cChannel
    }
    
    func requestPty(type: SSH.PtyType) throws {
        let code = libssh2_channel_request_pty_ex(cChannel,
                                                  type.rawValue, UInt32(type.rawValue.utf8.count),
                                                  nil, 0,
                                                  LIBSSH2_TERM_WIDTH, LIBSSH2_TERM_HEIGHT,
                                                  LIBSSH2_TERM_WIDTH_PX, LIBSSH2_TERM_WIDTH_PX)
        try LibSSH2Error.check(code: code)
    }
    
    func exec(command: String) throws {
        let code = libssh2_channel_process_startup(cChannel,
                                                   RawChannel.exec,
                                                   UInt32(RawChannel.exec.characters.count),
                                                   command,
                                                   UInt32(command.characters.count))
        try LibSSH2Error.check(code: code)
    }
    
    func readData() throws -> (data: Data, bytes: Int) {
        var data = Data(repeating: 0, count: bufferSize)
        
        let rc: Int = data.withUnsafeMutableBytes { (buffer: UnsafeMutablePointer<Int8>) in
            return libssh2_channel_read_ex(cChannel, 0, buffer, MemoryLayout<buffer>.size)
        }
        
        if rc < 0 {
            throw LibSSH2Error.error(Int32(rc))
        }
        
        return (data, rc)
    }
    
    func close() throws {
        let code = libssh2_channel_close(cChannel)
        try LibSSH2Error.check(code: code)
    }
    
    func waitClosed() throws {
        let code2 = libssh2_channel_wait_closed(cChannel)
        try LibSSH2Error.check(code: code2)
    }
    
    func exitStatus() -> Int32 {
        return libssh2_channel_get_exit_status(cChannel)
    }
    
    deinit {
        libssh2_channel_free(cChannel)
    }
    
}

class RawAgent {
    
    private let cAgent: OpaquePointer
    
    init(rawSession: RawSession) throws {
        guard let cAgent = libssh2_agent_init(rawSession.cSession) else {
            throw LibSSH2Error.initializationError
        }
        self.cAgent = cAgent
    }
    
    func connect() throws {
        let code = libssh2_agent_connect(cAgent)
        try LibSSH2Error.check(code: code)
    }
    
    func listIdentities() throws {
        let code = libssh2_agent_list_identities(cAgent)
        try LibSSH2Error.check(code: code)
    }
    
    func getIdentity(last: RawAgentPublicKey?) throws -> RawAgentPublicKey? {
        var publicKeyOptional: UnsafeMutablePointer<libssh2_agent_publickey>? = nil
        let code = libssh2_agent_get_identity(cAgent, UnsafeMutablePointer(mutating: &publicKeyOptional), last?.cIdentity)
        
        if code == 1 { // No more identities
            return nil
        }
        
        try LibSSH2Error.check(code: code)
        
        guard let publicKey = publicKeyOptional else {
            throw LibSSH2Error.initializationError
        }
        
        return RawAgentPublicKey(cIdentity: publicKey)
    }
    
    func authenticate(username: String, key: RawAgentPublicKey) -> Bool {
        let code = libssh2_agent_userauth(cAgent, username, key.cIdentity)
        return code == 0
    }
    
    deinit {
        libssh2_agent_disconnect(cAgent)
        libssh2_agent_free(cAgent)
    }
    
}

class RawAgentPublicKey {
    
    fileprivate let cIdentity: UnsafeMutablePointer<libssh2_agent_publickey>
    
    init(cIdentity: UnsafeMutablePointer<libssh2_agent_publickey>) {
        self.cIdentity = cIdentity
    }
    
}

extension RawAgentPublicKey: CustomStringConvertible {
    
    var description: String {
        return "Public key: " + String(cString: cIdentity.pointee.comment)
    }
    
}
