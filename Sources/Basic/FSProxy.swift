/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import POSIX
import libc

// FIXME: Eliminate this once we have a real Path type in Basic.
import Utility

public enum FSProxyError: ErrorProtocol {
    /// Access to the path is denied.
    ///
    /// This is used when an operation cannot be completed because a component of
    /// the path cannot be accessed.
    ///
    /// Used in situations that correspond to the POSIX EACCES error code.
    case invalidAccess
    
    /// No such path exists.
    ///
    /// This is used when a path specified does not exist, but it was expected
    /// to.
    ///
    /// Used in situations that correspond to the POSIX ENOENT error code.
    case noEntry
    
    /// Not a directory
    ///
    /// This is used when an operation cannot be completed because a component
    /// of the path which was expected to be a directory was not.
    ///
    /// Used in situations that correspond to the POSIX ENOTDIR error code.
    case notDirectory
    
    /// Invalid encoding
    ///
    /// This is used when an operation cannot be completed because a path could
    /// not be decoded correctly.
    ///
    /// Used in situations that correspond to the POSIX ENOTDIR error code.
    case invalidEncoding

    /// An unspecific operating system error.
    case unknownOSError
}

private extension FSProxyError {
    init(errno: Int32) {
        switch errno {
        case libc.EACCES:
            self = .invalidAccess
        case libc.ENOENT:
            self = .noEntry
        case libc.ENOTDIR:
            self = .notDirectory
        default:
            self = .unknownOSError
        }
    }
}

/// Abstracted access to file system operations.
///
/// This protocol is used to allow most of the codebase to interact with a
/// natural filesystem interface, while still allowing clients to transparently
/// substitute a virtual file system or redirect file system operations.
///
/// NOTE: All of these APIs are synchronous and can block.
//
// FIXME: Design an asynchronous story?
public protocol FSProxy {
    /// Check whether the given path exists and is accessible.
    func exists(_ path: String) -> Bool
    
    /// Check whether the given path is accessible and a directory.
    func isDirectory(_ path: String) -> Bool
    
    /// Get the contents of the given directory, in an undefined order.
    //
    // FIXME: Actual file system interfaces will allow more efficient access to
    // more data than just the name here.
    func getDirectoryContents(_ path: String) throws -> [String]
}

/// Concrete FSProxy implementation which communicates with the local file system.
private class LocalFS: FSProxy {
    func exists(_ path: String) -> Bool {
        return (try? stat(path)) != nil
    }
    
    func isDirectory(_ path: String) -> Bool {
        guard let status = try? stat(path) else {
            return false
        }
        // FIXME: We should probably have wrappers or something for this, so it
        // all comes from the POSIX module.
        return (status.st_mode & libc.S_IFDIR) != 0
    }
    
    func getDirectoryContents(_ path: String) throws -> [String] {
        guard let dir = libc.opendir(path) else {
            throw FSProxyError(errno: errno)
        }
        defer { _ = libc.closedir(dir) }
        
        var result: [String] = []
        var entry = dirent()
        
        while true {
            var entryPtr: UnsafeMutablePointer<dirent>? = nil
            if readdir_r(dir, &entry, &entryPtr) < 0 {
                // FIXME: Are there ever situation where we would want to
                // continue here?
                throw FSProxyError(errno: errno)
            }
            
            // If the entry pointer is null, we reached the end of the directory.
            if entryPtr == nil {
                break
            }
            
            // Otherwise, the entry pointer should point at the storage we provided.
            assert(entryPtr == &entry)
            
            // Add the entry to the result.
            guard let name = entry.name else {
                throw FSProxyError.invalidEncoding
            }
            
            // Ignore the pseudo-entries.
            if name == "." || name == ".." {
                continue
            }

            result.append(name)
        }
        
        return result
    }
}

/// Concrete FSProxy implementation which simulates an empty disk.
//
// FIXME: This class does not yet support concurrent mutation safely.
public class PseudoFS: FSProxy {
    private class Node {
        /// The actual node data.
        let contents: NodeContents
        
        init(_ contents: NodeContents) {
            self.contents = contents
        }
    }
    private enum NodeContents {
        case File(ByteString)
        case Directory(DirectoryContents)
    }    
    private class DirectoryContents {
        var entries:  [String: Node]

        init(entries: [String: Node] = [:]) {
            self.entries = entries
        }
    }
    
    /// The root filesytem.
    private var root: Node

    public init() {
        root = Node(.Directory(DirectoryContents()))
    }

    /// Get the node corresponding to get given path.
    private func getNode(_ path: String) throws -> Node? {
        func getNodeInternal(_ path: String) throws -> Node? {
            // If this is the root node, return it.
            if path == "/" {
                return root
            }

            // Otherwise, get the parent node.
            guard let parent = try getNodeInternal(path.parentDirectory) else {
                return nil
            }

            // If we didn't find a directory, this is an error.
            //
            // FIXME: Error handling.
            guard case .Directory(let contents) = parent.contents else {
                throw FSProxyError.notDirectory
            }

            // Return the directory entry.
            return contents.entries[path.basename]
        }

        // Get the node using the normalized path.
        precondition(path.isAbsolute, "input path must be absolute")
        return try getNodeInternal(path.normpath)
    }

    // MARK: FSProxy Implementation
    
    public func exists(_ path: String) -> Bool {
        do {
            return try getNode(path) != nil
        } catch {
            return false
        }
    }
    
    public func isDirectory(_ path: String) -> Bool {
        do {
            if case .Directory? = try getNode(path)?.contents {
                return true
            }
            return false
        } catch {
            return false
        }
    }
    
    public func getDirectoryContents(_ path: String) throws -> [String] {
        guard let node = try getNode(path) else {
            throw FSProxyError.noEntry
        }
        guard case .Directory(let contents) = node.contents else {
            throw FSProxyError.notDirectory
        }

        // FIXME: Perhaps we should change the protocol to allow lazy behavior.
        return [String](contents.entries.keys)
    }
}

/// Public access to the local FS proxy.
public let localFS: FSProxy = LocalFS()