import Foundation
import NIOCore
import NIOPosix

public nonisolated enum ProxyCommandError: Error, LocalizedError {
    case spawnFailed(String)
    case pipeUnavailable

    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let message): return "Couldn't start ProxyCommand: \(message)"
        case .pipeUnavailable: return "Couldn't wire up the ProxyCommand's input/output."
        }
    }
}

enum ProxyCommandTransport {
    static func expandTokens(_ template: String, host: String, port: Int, username: String) -> String {
        var result = ""
        var iterator = template.makeIterator()
        while let character = iterator.next() {
            guard character == "%" else {
                result.append(character)
                continue
            }
            guard let token = iterator.next() else {
                result.append(character)
                break
            }
            switch token {
            case "h": result += host
            case "p": result += String(port)
            case "r": result += username
            case "%": result.append("%")
            default:
                result.append(character)
                result.append(token)
            }
        }
        return result
    }

    static func connect(
        group: EventLoopGroup, commandLine: String, host: String, port: Int, username: String,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        let loop = group.next()
        let expanded = expandTokens(commandLine, host: host, port: port, username: username)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", expanded]
        let toProcess = Pipe()
        let fromProcess = Pipe()
        process.standardInput = toProcess
        process.standardOutput = fromProcess
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            return loop.makeFailedFuture(ProxyCommandError.spawnFailed(error.localizedDescription))
        }

        let readDescriptor = dup(fromProcess.fileHandleForReading.fileDescriptor)
        let writeDescriptor = dup(toProcess.fileHandleForWriting.fileDescriptor)
        fromProcess.fileHandleForReading.closeFile()
        toProcess.fileHandleForWriting.closeFile()
        guard readDescriptor >= 0, writeDescriptor >= 0 else {
            process.terminate()
            return loop.makeFailedFuture(ProxyCommandError.pipeUnavailable)
        }

        let channelFuture =
            NIOPipeBootstrap(group: loop)
            .channelInitializer(channelInitializer)
            .takingOwnershipOfDescriptors(input: readDescriptor, output: writeDescriptor)
        channelFuture.whenComplete { result in
            switch result {
            case .failure:
                if process.isRunning { process.terminate() }
            case .success(let channel):
                channel.closeFuture.whenComplete { _ in
                    if process.isRunning { process.terminate() }
                }
            }
        }
        return channelFuture
    }
}
