import Foundation
import Network

open class NWWebSocket: WebSocketConnection {

    // MARK: - Public properties

    public weak var delegate: WebSocketConnectionDelegate?

    public static var defaultOptions: NWProtocolWebSocket.Options {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true

        return options
    }

    // MARK: - Private properties

    private var connection: NWConnection?
    private let endpoint: NWEndpoint
    private let parameters: NWParameters
    private let connectionQueue: DispatchQueue
    private var pingTimer: Timer?
    private var intentionalDisconnect: Bool = false

    // MARK: - Initialization

    public convenience init(request: URLRequest,
                            connectAutomatically: Bool = false,
                            options: NWProtocolWebSocket.Options = NWWebSocket.defaultOptions,
                            connectionQueue: DispatchQueue = .main) {

        self.init(url: request.url!,
                  connectAutomatically: connectAutomatically,
                  connectionQueue: connectionQueue)
    }

    public init(url: URL,
                connectAutomatically: Bool = false,
                options: NWProtocolWebSocket.Options = NWWebSocket.defaultOptions,
                connectionQueue: DispatchQueue = .main) {

        endpoint = .url(url)

        if url.scheme == "ws" {
            parameters = NWParameters.tcp
        } else {
            parameters = NWParameters.tls
        }

        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        self.connectionQueue = connectionQueue

        if connectAutomatically {
            connect()
        }
    }

    // MARK: - WebSocketConnection conformance

    open func connect() {
        if connection == nil {
            connection = NWConnection(to: endpoint, using: parameters)
        }
        intentionalDisconnect = false
        connection?.stateUpdateHandler = stateDidChange(to:)
        listen()
        connection?.start(queue: connectionQueue)
    }

    open func send(string: String) {
        guard let data = string.data(using: .utf8) else {
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "textContext",
                                                  metadata: [metadata])

        send(data: data, context: context)
    }

    open func send(data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binaryContext",
                                                  metadata: [metadata])

        send(data: data, context: context)
    }

    public func listen() {
        connection?.receiveMessage { [weak self] (data, context, _, error) in
            guard let self = self else {
                return
            }

            if let data = data, !data.isEmpty, let context = context {
                self.receiveMessage(data: data, context: context)
            }

            if let error = error {
                if self.shouldReportNWError(error) {
                    self.delegate?.webSocketDidReceiveError(connection: self,
                                                            error: error)
                }
            } else {
                self.listen()
            }
        }
    }

    open func ping(interval: TimeInterval) {
        pingTimer = .scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else {
                return
            }

            self.ping()
        }
        pingTimer?.tolerance = 0.01
    }

    open func ping() {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(connectionQueue) { [weak self] error in
            guard let self = self else {
                return
            }

            self.delegate?.webSocketDidReceivePong(connection: self)

            if let error = error {
                self.delegate?.webSocketDidReceiveError(connection: self,
                                                        error: error)
            }
        }
        let context = NWConnection.ContentContext(identifier: "pingContext",
                                                  metadata: [metadata])

        send(data: Data(), context: context)
    }

    open func disconnect(closeCode: NWProtocolWebSocket.CloseCode = .protocolCode(.normalClosure)) {
        intentionalDisconnect = true

        // Call `cancel()` directly for a `normalClosure`
        // (Otherwise send the custom closeCode as a message).
        if closeCode == .protocolCode(.normalClosure) {
            connection?.cancel()
            delegate?.webSocketDidDisconnect(connection: self,
                                             closeCode: closeCode,
                                             reason: nil)
        } else {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = closeCode
            let context = NWConnection.ContentContext(identifier: "closeContext",
                                                      metadata: [metadata])

            // See implementation of `send(data:context:)` for `delegate?.webSocketDidDisconnect(…)`
            send(data: nil, context: context)
        }
    }

    // MARK: - Private methods

    /// The handler for managing changes to the `connection.state` via the `stateUpdateHandler` on a `NWConnection`.
    /// - Parameter state: The new `NWConnection.State`
    private func stateDidChange(to state: NWConnection.State) {
        switch state {
        case .ready:
            delegate?.webSocketDidConnect(connection: self)
        case .waiting(let error):
            delegate?.webSocketDidReceiveError(connection: self, error: error)
        case .failed(let error):
            stopConnection(error: error)
        case .setup:
            break
        case .preparing:
            break
        case .cancelled:
            stopConnection(error: nil)
        @unknown default:
            fatalError()
        }
    }

    /// Receive a WebSocket message, and handle it according to it's metadata.
    /// - Parameters:
    ///   - data: The `Data` that was received in the message.
    ///   - context: `ContentContext` representing the received message, and its metadata.
    private func receiveMessage(data: Data, context: NWConnection.ContentContext) {
        guard let metadata = context.protocolMetadata.first as? NWProtocolWebSocket.Metadata else {
            return
        }

        switch metadata.opcode {
        case .binary:
            self.delegate?.webSocketDidReceiveMessage(connection: self,
                                                      data: data)
        case .cont:
            //
            break
        case .text:
            guard let string = String(data: data, encoding: .utf8) else {
                return
            }
            self.delegate?.webSocketDidReceiveMessage(connection: self,
                                                      string: string)
        case .close:
            delegate?.webSocketDidDisconnect(connection: self,
                                             closeCode: metadata.closeCode,
                                             reason: data)
        case .ping:
            // SEE `autoReplyPing = true` in `init()`.
            break
        case .pong:
            // SEE `ping()` FOR PONG RECEIVE LOGIC.
            break
        @unknown default:
            fatalError()
        }
    }

    /// Send some `Data` over the  active `connection`.
    /// - Parameters:
    ///   - data: Some `Data` to send (this should be formatted as binary or UTF-8 encoded text).
    ///   - context: `ContentContext` representing the message to send, and its metadata.
    private func send(data: Data?, context: NWConnection.ContentContext) {
        connection?.send(content: data,
                         contentContext: context,
                         isComplete: true,
                         completion: .contentProcessed({ [weak self] error in
                            guard let self = self else {
                                return
                            }

                            // If a connection closure was sent, inform delegate on completion
                            if let socketMetadata = context.protocolMetadata.first as? NWProtocolWebSocket.Metadata,
                               socketMetadata.opcode == .close {
                                self.delegate?.webSocketDidDisconnect(connection: self,
                                                                      closeCode: socketMetadata.closeCode,
                                                                      reason: data)
                            }

                            if let error = error {
                                self.delegate?.webSocketDidReceiveError(connection: self, error: error)
                            }
                         }))
    }

    /// Tear down the `connection`.
    ///
    /// This method should only be called in response to a `connection` which has entered either
    /// a `cancelled` or `failed` state within the `stateUpdateHandler` closure.
    /// - Parameter error: error description
    private func stopConnection(error: NWError?) {
        if let error = error, shouldReportNWError(error) {
            delegate?.webSocketDidReceiveError(connection: self, error: error)
        }
        pingTimer?.invalidate()
        connection = nil
    }

    /// Determine if a Network error should be reported.
    ///
    /// POSIX errors of either `ENOTCONN` ("Socket is not connected") or
    /// `ECANCELED` ("Operation canceled") should not be reported if the disconnection was intentional.
    /// All other errors should be reported.
    /// - Parameter error: The `NWError` to inspect.
    /// - Returns: `true` if the error should be reported.
    private func shouldReportNWError(_ error: NWError) -> Bool {
        if case let .posix(code) = error,
           code == .ENOTCONN || code == .ECANCELED,
           intentionalDisconnect {
            return false
        } else {
            return true
        }
    }
}

