import Foundation

public enum RecognizedProxyCommand: Sendable, Equatable {
    case sshWJumpHost(bastion: String)
    case socks5(host: String, port: Int)
    case httpConnect(host: String, port: Int)
}

public enum ProxyCommandParser {
    public static func recognize(_ commandLine: String) -> RecognizedProxyCommand? {
        let tokens = tokenize(commandLine)
        guard let program = tokens.first?.split(separator: "/").last.map(String.init) else { return nil }

        switch program {
        case "ssh":
            return recognizeSSHDashW(Array(tokens.dropFirst()))
        case "nc", "ncat":
            return recognizeNetcatStyle(Array(tokens.dropFirst()))
        case "connect", "connect-proxy":
            return recognizeConnectProxy(Array(tokens.dropFirst()))
        case "corkscrew":
            return recognizeCorkscrew(Array(tokens.dropFirst()))
        default:
            return nil
        }
    }

    private static func tokenize(_ commandLine: String) -> [String] {
        commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static let sshFlagsWithArgument: Set<String> = [
        "-o", "-p", "-l", "-i", "-F", "-c", "-m", "-b", "-D", "-E", "-e", "-I", "-J", "-L", "-Q", "-R", "-S", "-w",
        "-B",
    ]

    private static func recognizeSSHDashW(_ args: [String]) -> RecognizedProxyCommand? {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-W" {
                index += 2
            } else if arg.hasPrefix("-W") && arg.count > 2 {
                index += 1
            } else if sshFlagsWithArgument.contains(arg) {
                index += 2
            } else if arg.hasPrefix("-") {
                index += 1
            } else {
                return .sshWJumpHost(bastion: arg)
            }
        }
        return nil
    }

    private static func splitHostPort(_ value: String) -> (host: String, port: Int)? {
        guard let colon = value.lastIndex(of: ":"),
            let port = Int(value[value.index(after: colon)...]),
            colon != value.startIndex
        else { return nil }
        return (String(value[..<colon]), port)
    }

    private static func recognizeNetcatStyle(_ args: [String]) -> RecognizedProxyCommand? {
        var proxyAddress: String?
        var wantsHTTP = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-x":
                index += 1
                guard index < args.count else { return nil }
                proxyAddress = args[index]
            case "-X":
                index += 1
                guard index < args.count else { return nil }
                let proto = args[index].lowercased()
                wantsHTTP = proto == "connect" || proto == "http"
            default:
                break
            }
            index += 1
        }
        guard let proxyAddress, let (host, port) = splitHostPort(proxyAddress) else { return nil }
        return wantsHTTP ? .httpConnect(host: host, port: port) : .socks5(host: host, port: port)
    }

    private static func recognizeConnectProxy(_ args: [String]) -> RecognizedProxyCommand? {
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-S":
                index += 1
                guard index < args.count, let (host, port) = splitHostPort(args[index]) else { return nil }
                return .socks5(host: host, port: port)
            case "-H":
                index += 1
                guard index < args.count, let (host, port) = splitHostPort(args[index]) else { return nil }
                return .httpConnect(host: host, port: port)
            default:
                break
            }
            index += 1
        }
        return nil
    }

    private static func recognizeCorkscrew(_ args: [String]) -> RecognizedProxyCommand? {
        let positional = args.filter { !$0.hasPrefix("-") }
        guard positional.count >= 2, let port = Int(positional[1]) else { return nil }
        return .httpConnect(host: positional[0], port: port)
    }
}
