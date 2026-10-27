import Foundation
import Darwin

// One-shot crash recovery only. The main app starts this executable immediately
// before writing Dock preferences and waits for the READY handshake.
guard CommandLine.arguments.count == 5,
      let pid = Int32(CommandLine.arguments[1]), pid > 1,
      let session = UUID(uuidString: CommandLine.arguments[2]) else { exit(2) }

let stateURL = URL(fileURLWithPath: CommandLine.arguments[3])
let lockURL = URL(fileURLWithPath: CommandLine.arguments[4])
guard let snapshot = try? SystemDockRecovery.load(stateURL),
      snapshot.sessionID == session, snapshot.ownerPID == pid,
      snapshot.phase == "prepared" else { exit(3) }

let queue = kqueue()
guard queue >= 0 else { exit(4) }
defer { close(queue) }
var registration = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC),
                          flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                          fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
guard kevent(queue, &registration, 1, nil, 0, nil) == 0 else { exit(5) }
let ready = Array("READY\n".utf8)
_ = ready.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }

var event = kevent()
guard kevent(queue, nil, 0, &event, 1, nil) == 1 else { exit(6) }

// The same advisory lock is held by the app until normal restoration or exit.
// It serializes a new launch, the old watchdog, and any recovery attempt.
let fd = open(lockURL.path, O_RDWR | O_CLOEXEC)
guard fd >= 0 else { exit(7) }
defer { SystemDockRecovery.unlock(fd) }
guard flock(fd, LOCK_EX) == 0 else { exit(8) }
guard let pending = try? SystemDockRecovery.load(stateURL),
      pending.sessionID == session, pending.ownerPID == pid else { exit(0) }
do {
    _ = try SystemDockRecovery.restore(stateURL, backend: LiveSystemDockPreferences())
} catch {
    // Keep the snapshot for recovery on the next application launch.
    fputs("WMacDockWatchdog: \(error.localizedDescription)\n", stderr)
    exit(9)
}
