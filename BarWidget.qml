import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// event-widget — the next event, right in the bar.
//
// Left click opens the meeting list; right click joins the next meeting;
// middle click refetches the calendar. When there is nothing actionable
// (no feed configured, or no upcoming meeting) the widget shrinks to a
// muted camera glyph that still opens the panel.
BarWidget {
  id: root
  moduleName: "guilhermeris.event-widget"

  // ---- settings (shell.json layout entry, `omarchy bar set`)
  readonly property string icsUrl: String(setting("icsUrl", "") || "").trim()
  readonly property string icsUrl2: String(setting("icsUrl2", "") || "").trim()
  readonly property int refreshMinutes: Math.max(1, parseInt(setting("refreshMinutes", 5), 10) || 5)
  readonly property int showDaysAhead: Math.max(1, parseInt(setting("showDaysAhead", 3), 10) || 3)
  readonly property int maxTitleLength: Math.max(8, parseInt(setting("maxTitleLength", 28), 10) || 28)
  readonly property bool showOnlyWithVideoLink: {
    var v = setting("showOnlyWithVideoLink", true)
    if (v === undefined || v === null) return true
    if (v === true || v === 1 || v === "1") return true
    if (v === false || v === 0 || v === "0") return false
    return String(v).toLowerCase() !== "false"
  }
  readonly property string browserCommand: String(setting("browserCommand", "") || "").trim()
  readonly property string todoistApiToken: String(setting("todoistApiKey", "") || "").trim()
  readonly property string todoistApiBase: "https://api.todoist.com/api/v1"
  // ---- state
  readonly property bool configured: icsUrl !== "" || icsUrl2 !== ""
  property var rawEvents: []
  property var meetings: []
  property var upcomingToday: []
  property var scheduleGroups: []
  property var nextMeeting: null
  property date lastUpdated: new Date(0)
  property bool lastFetchFailed: false
  property bool fetchBusy: false
  readonly property bool fetching: fetchBusy
  property date now: new Date()
  property string primaryFeedText: ""
  property string secondaryFeedText: ""
  property bool primaryFetchFailed: false
  property bool secondaryFetchFailed: false
  property bool primaryFetchFinished: false
  property bool secondaryFetchFinished: false
  property int pendingFetches: 0
  property var todoistCompletedIds: []
  property var todoistCompletingIds: []
  property string todoistError: ""

  readonly property string label: configured && nextMeeting
    ? (nextMeeting.meetUrl ? "  " : "󰃯  ") + Model.formatLabel(nextMeeting, root.now, maxTitleLength)
    : ""
  readonly property bool inMeeting: nextMeeting
    && nextMeeting.start && nextMeeting.end
    && root.now.getTime() >= nextMeeting.start.getTime()
    && root.now.getTime() < nextMeeting.end.getTime()

  // ---- actions
  function openMeetingUrl(url) {
    if (!url) return
    var quote = Util.shellQuote(url)
    if (browserCommand !== "") bar.run(browserCommand + " " + quote)
    else bar.run("xdg-open " + quote)
  }

  function joinMeeting(event) {
    if (event && event.meetUrl) openMeetingUrl(event.meetUrl)
  }

  function openCalendar(event) {
    if (event && event.url) openMeetingUrl(event.url)
  }

  function openEvent(event) {
    if (!event) return
    if (event.meetUrl) openMeetingUrl(event.meetUrl)
    else openCalendar(event)
  }

  function canCompleteTodoist(event) {
    return !!(event && event.todoistTaskId && root.todoistApiToken !== "")
  }

  function isTodoistCompleting(event) {
    return !!(event && event.todoistTaskId
      && root.todoistCompletingIds.indexOf(event.todoistTaskId) !== -1)
  }

  function completeTodoist(event) {
    if (!root.canCompleteTodoist(event) || root.isTodoistCompleting(event)) return
    var taskId = String(event.todoistTaskId)
    root.todoistCompletingIds = root.todoistCompletingIds.concat([taskId])
    todoistActionProc.pendingTaskId = taskId
    todoistActionProc.stdinEnabled = true
    todoistActionProc.command = ["curl", "-fsS", "--max-time", "10", "-K", "-", "-X", "POST",
      root.todoistApiBase + "/tasks/" + encodeURIComponent(taskId) + "/close"]
    todoistActionProc.running = true
  }

  function onTodoistActionExited(exitCode) {
    var taskId = todoistActionProc.pendingTaskId
    root.todoistCompletingIds = root.todoistCompletingIds.filter(function(id) { return id !== taskId })
    if (exitCode !== 0) {
      root.todoistError = "Couldn't complete the Todoist task."
      root.meetingDataChanged()
      return
    }

    root.todoistError = ""
    if (root.todoistCompletedIds.indexOf(taskId) === -1)
      root.todoistCompletedIds = root.todoistCompletedIds.concat([taskId])
    root.rawEvents = root.rawEvents.filter(function(event) {
      return !event || event.todoistTaskId !== taskId
    })
    root.recalc()
  }

  // The feed URL is a credential, so it must never appear in a process
  // argument list where every local user can read it. curl gets it over
  // stdin as a `-K -` config line.
  function fetchCalendar() {
    if (!root.configured || root.fetchBusy || fetchProc.running || fetchProc2.running) return

    root.fetchBusy = true
    root.primaryFeedText = ""
    root.secondaryFeedText = ""
    root.primaryFetchFailed = false
    root.secondaryFetchFailed = false
    root.primaryFetchFinished = false
    root.secondaryFetchFinished = false
    root.pendingFetches = (root.icsUrl !== "" ? 1 : 0) + (root.icsUrl2 !== "" ? 1 : 0)

    if (root.icsUrl !== "") {
      fetchProc.stdinEnabled = true
      fetchProc.command = ["curl", "-fsSL", "--max-time", "15", "-K", "-"]
      fetchProc.running = true
    }
    if (root.icsUrl2 !== "") {
      fetchProc2.stdinEnabled = true
      fetchProc2.command = ["curl", "-fsSL", "--max-time", "15", "-K", "-"]
      fetchProc2.running = true
    }
    fetchTimeout.restart()
  }

  function refresh() {
    fetchCalendar()
  }

  function onCalendarsFetched() {
    var feedTexts = [root.primaryFeedText, root.secondaryFeedText]
    var events = []
    var receivedFeed = false

    for (var i = 0; i < feedTexts.length; i++) {
      var text = String(feedTexts[i] || "").trim()
      if (!text) continue
      receivedFeed = true
      var parsed = Model.parseIcs(text, {
        lookaheadDays: root.showDaysAhead + 1,
        maxEvents: 80,
        now: root.now,
        todoistFeed: /todoist\.com/i.test(i === 0 ? root.icsUrl : root.icsUrl2)
      })
      for (var j = 0; j < parsed.length; j++) events.push(parsed[j])
    }

    if (!receivedFeed) {
      root.lastFetchFailed = true
      root.meetingDataChanged()
      return
    }

    root.rawEvents = events.filter(function(event) {
      return !event || !event.todoistTaskId
        || root.todoistCompletedIds.indexOf(event.todoistTaskId) === -1
    })
    root.meetings = Model.buildUpcoming(root.rawEvents, root.now, {
      lookaheadDays: root.showDaysAhead,
      showOnlyWithVideoLink: root.showOnlyWithVideoLink,
      maxRows: 8
    })
    root.upcomingToday = Model.upcomingToday(root.rawEvents, root.now)
    root.scheduleGroups = Model.buildScheduleGroups(root.rawEvents, root.now, {
      lookaheadDays: root.showDaysAhead,
      maxRows: 20
    })
    root.nextMeeting = root.meetings.length > 0 ? root.meetings[0] : null
    root.lastUpdated = new Date()
    root.lastFetchFailed = root.primaryFetchFailed || root.secondaryFetchFailed
    root.meetingDataChanged()
  }

  function onFeedExited(index, exitCode) {
    if (index === 0) {
      if (root.primaryFetchFinished) return
      root.primaryFetchFinished = true
      root.primaryFetchFailed = exitCode !== 0
    } else {
      if (root.secondaryFetchFinished) return
      root.secondaryFetchFinished = true
      root.secondaryFetchFailed = exitCode !== 0
    }

    root.pendingFetches = Math.max(0, root.pendingFetches - 1)
    if (root.pendingFetches === 0) {
      fetchTimeout.stop()
      root.fetchBusy = false
      root.onCalendarsFetched()
    }
  }

  function onFetchTimeout() {
    if (!root.fetchBusy) return
    if (fetchProc.running) fetchProc.running = false
    if (fetchProc2.running) fetchProc2.running = false
    root.fetchBusy = false
    root.lastFetchFailed = true
    root.meetingDataChanged()
  }

  function recalc() {
    if (root.rawEvents && root.rawEvents.length > 0) {
      root.meetings = Model.buildUpcoming(root.rawEvents, root.now, {
        lookaheadDays: root.showDaysAhead,
        showOnlyWithVideoLink: root.showOnlyWithVideoLink,
        maxRows: 8
      })
      root.upcomingToday = Model.upcomingToday(root.rawEvents, root.now)
      root.scheduleGroups = Model.buildScheduleGroups(root.rawEvents, root.now, {
        lookaheadDays: root.showDaysAhead,
        maxRows: 20
      })
      root.nextMeeting = root.meetings.length > 0 ? root.meetings[0] : null
    } else {
      root.nextMeeting = root.meetings.length > 0 ? root.meetings[0] : null
    }
    root.meetingDataChanged()
  }

  signal meetingDataChanged()

  // ---- panel plumbing (shape contract for shell.summon/hide/toggle)
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: {
    injectPanel()
    root.recalc()
    Qt.callLater(root.fetchCalendar)
  }
  onMeetingDataChanged: {
    if (panelLoader.item) panelLoader.item.reload()
  }

  // Refetch the calendar on a schedule.
  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.fetchCalendar()
  }

  // Keep the countdown fresh.
  Timer {
    id: nowTimer
    interval: 30 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.now = new Date()
      root.recalc()
    }
  }

  // curl has its own network timeout, but keep the UI recoverable if a
  // process or its completion signal gets stuck inside the shell.
  Timer {
    id: fetchTimeout
    interval: 20 * 1000
    repeat: false
    onTriggered: root.onFetchTimeout()
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.primaryFeedText = text
    }
    onStarted: {
      fetchProc.write("url = \"" + root.icsUrl.replace(/([\\"])/g, "\\$1") + "\"\n")
      fetchProc.stdinEnabled = false
    }
    onExited: function(exitCode) {
      root.onFeedExited(0, exitCode)
    }
  }

  Process {
    id: fetchProc2
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.secondaryFeedText = text
    }
    onStarted: {
      fetchProc2.write("url = \"" + root.icsUrl2.replace(/([\\"])/g, "\\$1") + "\"\n")
      fetchProc2.stdinEnabled = false
    }
    onExited: function(exitCode) {
      root.onFeedExited(1, exitCode)
    }
  }

  Process {
    id: todoistActionProc
    property string pendingTaskId: ""
    stderr: StdioCollector {
      id: todoistActionErr
      waitForEnd: true
    }
    onStarted: {
      todoistActionProc.write("header = \"Authorization: Bearer " + root.todoistApiToken + "\"\n")
      todoistActionProc.stdinEnabled = false
    }
    onExited: function(exitCode) { root.onTodoistActionExited(exitCode) }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label !== "" ? root.label : "󰃲"
    labelVisible: true
    hasVisualContent: true
    dimmed: root.label === ""
    active: root.inMeeting
    useActiveColor: false
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: root.tooltipLine

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.nextMeeting && root.nextMeeting.meetUrl) root.joinMeeting(root.nextMeeting)
        else root.toggle()
      } else if (b === Qt.MiddleButton) {
        root.refresh()
      } else {
        root.toggle()
      }
    }
  }

  readonly property string tooltipLine: {
    if (!root.configured) return "event-widget — No calendar configured"
    if (!root.nextMeeting) return "event-widget — No upcoming events" + (root.lastFetchFailed ? " (offline)" : "")
    var title = root.nextMeeting.title || "(Untitled)"
    var range = Model.timeRange(root.nextMeeting.start, root.nextMeeting.end)
    var status = Model.relativeStatus(root.nextMeeting, root.now)
    var line = title + " · " + range + (status ? " (" + status + ")" : "")
    if (root.lastFetchFailed) line += " · Offline"
    return line
  }
}
