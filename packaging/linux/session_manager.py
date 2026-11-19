#!/usr/bin/env python3
"""Stands in for gnome-session on smoke_test.sh's private session bus.

    session_manager.py <app id>

GTK registers an app with whatever owns org.gnome.SessionManager when the app
starts. This owns it, so the smoke test can log the app out the way GNOME
does: QueryEndSession first, a question the user can still answer with
Cancel, then CancelEndSession or EndSession.

Other clients register too, the accessibility bus among them, and each gets a
client of its own that is never signalled. Only <app id> is logged out: each
line on stdin sends it one of those signals, and each thing it says back is
printed as a line of its own:

    query    QueryEndSession       ready                      (name owned)
    cancel   CancelEndSession      registered <app id>
    end      EndSession            inhibit <cookie> <flags> <reason>
                                   response <true|false>      (EndSessionResponse)
                                   uninhibit <cookie>
                                   unregistered
"""

import itertools
import sys
import threading

from gi.repository import Gio, GLib

APP_ID = sys.argv[1]
MANAGER = "/org/gnome/SessionManager"
NODE = Gio.DBusNodeInfo.new_for_xml(
    """
<node>
  <interface name="org.gnome.SessionManager">
    <method name="RegisterClient">
      <arg type="s" direction="in"/>
      <arg type="s" direction="in"/>
      <arg type="o" direction="out"/>
    </method>
    <method name="UnregisterClient">
      <arg type="o" direction="in"/>
    </method>
    <method name="Inhibit">
      <arg type="s" direction="in"/>
      <arg type="u" direction="in"/>
      <arg type="s" direction="in"/>
      <arg type="u" direction="in"/>
      <arg type="u" direction="out"/>
    </method>
    <method name="Uninhibit">
      <arg type="u" direction="in"/>
    </method>
  </interface>
  <interface name="org.gnome.SessionManager.ClientPrivate">
    <method name="EndSessionResponse">
      <arg type="b" direction="in"/>
      <arg type="s" direction="in"/>
    </method>
    <signal name="QueryEndSession"><arg type="u"/></signal>
    <signal name="EndSession"><arg type="u"/></signal>
    <signal name="CancelEndSession"/>
    <signal name="Stop"/>
  </interface>
</node>
"""
)
SIGNALS = {
    "query": ("QueryEndSession", GLib.Variant("(u)", (0,))),
    "cancel": ("CancelEndSession", None),
    "end": ("EndSession", GLib.Variant("(u)", (0,))),
}
clients = itertools.count(1)
cookies = itertools.count(1)
app = {"client": None, "cookies": set()}
loop = GLib.MainLoop()


def say(*words):
    print(*words, flush=True)


def method_call(connection, sender, path, interface, method, parameters, invocation):
    args = parameters.unpack()
    reply = None
    if method == "GetAll":
        # GTK's proxy for the client loads its properties. It has none.
        reply = GLib.Variant("(a{sv})", ({},))
    elif method == "RegisterClient":
        client = f"{MANAGER}/Client{next(clients)}"
        connection.register_object(client, NODE.interfaces[1], method_call, None, None)
        if args[0] == APP_ID:
            app["client"] = client
            say("registered", args[0])
        reply = GLib.Variant("(o)", (client,))
    elif method == "UnregisterClient":
        if args[0] == app["client"]:
            say("unregistered")
    elif method == "Inhibit":
        cookie = next(cookies)
        if args[0] == APP_ID:
            app["cookies"].add(cookie)
            say("inhibit", cookie, args[3], args[2])
        reply = GLib.Variant("(u)", (cookie,))
    elif method == "Uninhibit":
        if args[0] in app["cookies"]:
            say("uninhibit", args[0])
    elif method == "EndSessionResponse":
        if path == app["client"]:
            say("response", "true" if args[0] else "false")
    invocation.return_value(reply)


def commands(connection):
    for line in sys.stdin:
        signal, parameters = SIGNALS[line.strip()]
        connection.emit_signal(
            None, app["client"], NODE.interfaces[1].name, signal, parameters
        )
    loop.quit()


def bus_acquired(connection, name):
    connection.register_object(MANAGER, NODE.interfaces[0], method_call, None, None)
    threading.Thread(target=commands, args=(connection,), daemon=True).start()


Gio.bus_own_name(
    Gio.BusType.SESSION,
    "org.gnome.SessionManager",
    Gio.BusNameOwnerFlags.NONE,
    bus_acquired,
    lambda connection, name: say("ready"),
    lambda connection, name: loop.quit(),
)
loop.run()
