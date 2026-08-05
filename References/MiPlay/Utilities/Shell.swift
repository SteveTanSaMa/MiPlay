//
//  Shell.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

enum Shell {
    enum ShellError: LocalizedError {
        case commandNotFound(String)
        case nonZeroExit(code: Int, output: String, error: String)

        var errorDescription: String? {
            switch self {
            case .commandNotFound(let cmd): return "命令未找到: \(cmd)"
            case .nonZeroExit(let code, let output, let error):
                return "命令退出码 \(code):\n输出: \(output)\n错误: \(error)"
            }
        }
    }

    @discardableResult
    static func run(
        _ command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var env = ProcessInfo.processInfo.environment
        if let environment = environment {
            env.merge(environment) { (_, new) in new }
        }
        process.environment = env

        if let workingDirectory = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        if arguments.isEmpty {
            process.arguments = ["-c", command]
        } else {
            process.arguments = [command] + arguments
        }

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw ShellError.nonZeroExit(
                code: Int(process.terminationStatus),
                output: output,
                error: error
            )
        }

        return output
    }

    @discardableResult
    static func runAsync(
        _ command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        outputHandler: ((String) -> Void)? = nil
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var env = ProcessInfo.processInfo.environment
        if let environment = environment {
            env.merge(environment) { (_, new) in new }
        }
        process.environment = env

        if let workingDirectory = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        if arguments.isEmpty {
            process.arguments = ["-c", command]
        } else {
            process.arguments = [command] + arguments
        }

        if let outputHandler = outputHandler {
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    outputHandler(output)
                }
            }
        }

        try process.run()
        return process
    }
}
