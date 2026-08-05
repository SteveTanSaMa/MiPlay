//
//  GameLocation.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Architecture Design -> Domain Model -> GameLocation
// Source: Architecture Design -> Communication -> security-scoped bookmark

/// Persistent authorization facts for one selected game directory.
public struct GameLocation: Codable, Sendable, Equatable {
    public enum Scope: String, Codable, Sendable {
        case readOnly
        case readWrite
    }

    public enum ResolutionState: String, Codable, Sendable {
        case missing
        case resolvable
        case stale
        case accessDenied
        case resourceUnavailable
        case migrationRequired
    }

    public let gameID: String
    public var bookmarkData: Data?
    public var lastKnownPath: String?
    public var scope: Scope
    public var resolutionState: ResolutionState
    public var lastResolvedAt: Date?
    public var bookmarkVersion: Int

    nonisolated public init(
        gameID: String,
        bookmarkData: Data?,
        lastKnownPath: String?,
        scope: Scope = .readOnly,
        resolutionState: ResolutionState,
        lastResolvedAt: Date? = nil,
        bookmarkVersion: Int = 1
    ) {
        self.gameID = gameID
        self.bookmarkData = bookmarkData
        self.lastKnownPath = lastKnownPath
        self.scope = scope
        self.resolutionState = resolutionState
        self.lastResolvedAt = lastResolvedAt
        self.bookmarkVersion = bookmarkVersion
    }

    nonisolated public static func migrationRequired(gameID: String, path: String) -> GameLocation {
        GameLocation(
            gameID: gameID,
            bookmarkData: nil,
            lastKnownPath: path,
            resolutionState: .migrationRequired
        )
    }

    /// Compares durable authorization facts without treating a successful access
    /// timestamp as a migration. A changed bookmark or resolved path must be
    /// committed before the caller reports the operation as successful.
    nonisolated public func requiresPersistenceUpdate(from original: GameLocation) -> Bool {
        bookmarkData != original.bookmarkData ||
        lastKnownPath != original.lastKnownPath ||
        scope != original.scope ||
        resolutionState != original.resolutionState ||
        bookmarkVersion != original.bookmarkVersion
    }

    nonisolated public static func == (lhs: GameLocation, rhs: GameLocation) -> Bool {
        lhs.gameID == rhs.gameID &&
        lhs.bookmarkData == rhs.bookmarkData &&
        lhs.lastKnownPath == rhs.lastKnownPath &&
        lhs.scope == rhs.scope &&
        lhs.resolutionState == rhs.resolutionState &&
        lhs.lastResolvedAt == rhs.lastResolvedAt &&
        lhs.bookmarkVersion == rhs.bookmarkVersion
    }
}
