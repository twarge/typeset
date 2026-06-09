// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
import CoreServices
import Foundation

/// Watches a folder tree for external changes (files added/removed/renamed and
/// existing-file content edits) using FSEvents. It deliberately carries **no**
/// payload: every event simply pings `onChange`, and the caller re-reads the
/// tree and diffs it against its own snapshot. That keeps correctness
/// independent of FSEvents' event fidelity (it can coalesce or drop to
/// directory granularity under load).
///
/// FSEvents — not a per-file `DispatchSource` — because atomic saves (temp file
/// + rename, which both other programs and our own write-through use) swap the
/// inode and would silently break an fd-based watcher. FSEvents tracks by path
/// and survives atomic replaces.
///
/// Lifetime: the stream's context holds a **retained** reference to this object
/// (balanced by the `release` callback when the stream is released), so a
/// callback can never run against a freed instance. `stop()` additionally drains
/// the private queue so no in-flight callback outlives teardown.
final class DirectoryWatcher {
    private let queue = DispatchQueue(label: "com.twarge.typeset.directorywatcher")
    private var stream: FSEventStreamRef?
    /// Invoked (on the private queue) for every coalesced batch of events. The
    /// caller is responsible for hopping to the main actor. Only mutated under
    /// the drain protocol in `stop()`, so reads from `fire()` are well-ordered.
    private var onChange: (() -> Void)?

    /// Starts watching `rootURL`. Returns `nil` if the stream can't be created.
    init?(rootURL: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange

        // The stream keeps a strong reference to `self` via `info`; `release`
        // balances it when the stream is released in `stop()`.
        let retained = Unmanaged.passRetained(self)
        var context = FSEventStreamContext(
            version: 0,
            info: retained.toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<DirectoryWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().fire()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else {
            // No stream means the `release` callback will never fire, so balance
            // the `passRetained` ourselves.
            retained.release()
            return nil
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func fire() {
        onChange?()
    }

    /// Stops and releases the stream. Safe to call more than once. After
    /// `FSEventStreamInvalidate` no new callbacks are scheduled; `queue.sync`
    /// then waits for any in-flight callback on the serial queue to finish, so
    /// nothing can touch a torn-down view after this returns.
    func stop() {
        guard let stream else {
            onChange = nil
            return
        }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        queue.sync {}
        onChange = nil
        FSEventStreamRelease(stream)
    }

    deinit {
        stop()
    }
}
#endif
