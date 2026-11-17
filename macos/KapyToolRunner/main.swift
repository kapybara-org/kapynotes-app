import Foundation
import XPC

// A run whose stdin closed early must not take the helper with it.
signal(SIGPIPE, SIG_IGN)

xpc_main { peer in
  Listener.accept(peer, requirement: Listener.peerRequirement, handle: ToolRunner.handle)
}
