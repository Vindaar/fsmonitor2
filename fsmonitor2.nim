#
#
#            Nim's Runtime Library
#        (c) Copyright 2012 Dominik Picheta
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

when defined(linux) or defined(nimdoc):
  from posix import read
  import inotify
else:
  {.error: "Your platform is not supported.".}

import os, asyncdispatch, tables, macros

type
  FD = cint
  WD = cint
  FSMonitor* = ref FSMonitorObj
  FSMonitorObj = object of RootObj
    fd: AsyncFD
    handleEvents: seq[proc (action: MonitorEvent)]
    targets: Table[WD, string]

  MonitorEventType* = enum ## Monitor event type
    MonitorAccess,       ## File was accessed.
    MonitorAttrib,       ## Metadata changed.
    MonitorCloseWrite,   ## Writable file was closed.
    MonitorCloseNoWrite, ## Non-writable file closed.
    MonitorCreate,       ## Subfile was created.
    MonitorDelete,       ## Subfile was deleted.
    MonitorDeleteSelf,   ## Watched file/directory was itself deleted.
    MonitorModify,       ## File was modified.
    MonitorMoveSelf,     ## Self was moved.
    MonitorMoved,        ## File was moved.
    MonitorOpen,         ## File was opened.
    MonitorAll           ## Filter for all event types.

  MonitorEvent* = object
    case kind*: MonitorEventType  ## Type of the event.
    of MonitorMoveSelf, MonitorMoved:
      oldPath*: string          ## Old absolute location
      newPath*: string          ## New absolute location
    else:
      fullname*: string         ## Absolute filename of the file/directory affected.
    name*: string             ## Non absolute filepath of the file/directory
                              ## affected relative to the directory watched.
                              ## "" if this event refers to the file/directory
                              ## watched.
    when defined(unix):
      wd*: WD                   ## Watch descriptor.

const
  MaxEvents = 100

proc newMonitor*(): FSMonitor =
  ## Creates a new file system monitor.
  new(result)
  result.targets = initTable[cint, string]()
  let fd = inotifyInit()
  if fd < 0:
    raiseOSError(osLastError())
  result.fd = AsyncFD(fd)
  register(result.fd)

proc add*(monitor: FSMonitor, target: string,
          filters = {MonitorAll}): cint {.discardable.} =
  ## Adds ``target`` which may be a directory or a file to the list of
  ## watched paths of ``monitor``.
  ## You can specify the events to report using the ``filters`` parameter.

  var INFilter = 0
  for f in filters:
    case f
    of MonitorAccess: INFilter = INFilter or IN_ACCESS
    of MonitorAttrib: INFilter = INFilter or IN_ATTRIB
    of MonitorCloseWrite: INFilter = INFilter or IN_CLOSE_WRITE
    of MonitorCloseNoWrite: INFilter = INFilter or IN_CLOSE_NO_WRITE
    of MonitorCreate: INFilter = INFilter or IN_CREATE
    of MonitorDelete: INFilter = INFilter or IN_DELETE
    of MonitorDeleteSelf: INFilter = INFilter or IN_DELETE_SELF
    of MonitorModify: INFilter = INFilter or IN_MODIFY
    of MonitorMoveSelf: INFilter = INFilter or IN_MOVE_SELF
    of MonitorMoved: INFilter = INFilter or IN_MOVED_FROM or IN_MOVED_TO
    of MonitorOpen: INFilter = INFilter or IN_OPEN
    of MonitorAll: INFilter = INFilter or IN_ALL_EVENTS

  result = inotifyAddWatch(monitor.fd.cint, target, INFilter.uint32)
  if result < 0:
    raiseOSError(osLastError())
  monitor.targets.add(result, target)

proc del*(monitor: FSMonitor, wd: cint) =
  ## Removes watched directory or file as specified by ``wd`` from ``monitor``.
  ##
  ## If ``wd`` is not a part of ``monitor`` an OSError error is raised.
  if inotifyRmWatch(monitor.fd.cint, wd) < 0:
    raiseOSError(osLastError())

proc readEvents*(monitor: FSMonitor): Future[seq[MonitorEvent]] =
  # extract FD from FSMonitor for local use
  let fd = monitor.fd.cint
  # not using `result` var, since we mutate in `cb` callback impl
  var retFuture = newFuture[seq[MonitorEvent]]("fsmonitor2.readEvents")

  let eventSize = sizeof(InotifyEvent) - sizeof(cstring)
  let bufLen = 1024 * (eventSize + 16)
  var readBuffer = newString(bufLen)

  # store moved watch descriptors
  var movedFrom = initTable[cint, tuple[wd: WD, old: string]]()

  proc cb(fd: AsyncFD): bool =
    result = true
    let length = read(fd.cint, addr readBuffer[0], bufLen)

    if length < 0:
      result = false
    else:
      var monEvents = newSeq[MonitorEvent]()
      var i = 0
      while i < length:
        let event = cast[ptr InotifyEvent](addr readBuffer[i])
        var mev: MonitorEvent
        mev.wd = event.wd

        if event.len.int != 0:
          let cstr = event.name.addr.cstring
          mev.name = $cstr
        else:
          mev.name = ""

        if (event.mask.int and IN_MOVED_FROM) != 0:
          # Moved from event, add to m's collection
          movedFrom.add(event.cookie.cint, (mev.wd, mev.name))
          inc(i, sizeof(INotifyEvent) + event.len.int)
          # TODO: understand why we continue here
          continue
        elif (event.mask.int and IN_MOVED_TO) != 0:
          mev.kind = MonitorMoved
          assert movedFrom.hasKey(event.cookie.cint)
          # Find the MovedFrom event.
          mev.oldPath = monitor.targets[mev.wd] / movedFrom[event.cookie.cint].old
          mev.newPath = monitor.targets[mev.wd] / mev.name
          # Delete it from the Table
          movedFrom.del(event.cookie.cint)
        elif (event.mask.int and IN_ACCESS) != 0: mev.kind = MonitorAccess
        elif (event.mask.int and IN_ATTRIB) != 0: mev.kind = MonitorAttrib
        elif (event.mask.int and IN_CLOSE_WRITE) != 0:
          mev.kind = MonitorCloseWrite
        elif (event.mask.int and IN_CLOSE_NOWRITE) != 0:
          mev.kind = MonitorCloseNoWrite
        elif (event.mask.int and IN_CREATE) != 0: mev.kind = MonitorCreate
        elif (event.mask.int and IN_DELETE) != 0:
          mev.kind = MonitorDelete
        elif (event.mask.int and IN_DELETE_SELF) != 0:
          mev.kind = MonitorDeleteSelf
        elif (event.mask.int and IN_MODIFY) != 0: mev.kind = MonitorModify
        elif (event.mask.int and IN_MOVE_SELF) != 0:
          mev.kind = MonitorMoveSelf
        elif (event.mask.int and IN_OPEN) != 0: mev.kind = MonitorOpen

        monEvents.add(mev)
        i += eventSize + event.len.int

        # create full name if `WD` known and not `MonitorMoved`
        if mev.kind != MonitorMoved and mev.wd in monitor.targets:
          mev.fullname = monitor.targets[mev.wd] / mev.name

      # If movedFrom events have not been matched with a moveTo. File has
      # been moved to an unwatched location, emit a MonitorDelete.
      for cookie, t in pairs(movedFrom):
        var mev: MonitorEvent
        mev.kind = MonitorDelete
        mev.wd = t.wd
        mev.name = t.old
        monEvents.add(mev)

      retFuture.complete(monEvents)

  addRead(AsyncFD(fd), cb)
  result = retFuture

proc register*(monitor: FSMonitor, cb: proc (ev: MonitorEvent)) =
  monitor.handleEvents.add cb

proc read*(monitor: FSMonitor): Future[seq[MonitorEvent]] =
  result = readEvents(monitor)

proc watch*(monitor: FSMonitor) =
  var fut = monitor.read()
  fut.callback = proc () =
    for cb in monitor.handleEvents:
      for action in fut.read():
        cb(action)
    monitor.watch()

when not defined(testing) and isMainModule:
  proc main =
    var
      monitor = newMonitor()
      n = 0
    n = monitor.add("/tmp")
    assert n == 1
    n = monitor.add("/tmp", {MonitorAll})
    assert n == 1
    n = monitor.add("/tmp", {MonitorCloseWrite, MonitorCloseNoWrite})
    assert n == 1
    n = monitor.add("/tmp", {MonitorMoved, MonitorOpen, MonitorAccess})
    assert n == 1
    monitor.register(
      proc (ev: MonitorEvent) =
        echo("Got event: ", ev.kind)
        if ev.kind == MonitorMoved:
          echo("From ", ev.oldPath, " to ", ev.newPath)
          echo("Name is ", ev.name)
        else:
          echo("Name ", ev.name, " fullname ", ev.fullName)
    )

    monitor.watch()
    runForever()
  main()
