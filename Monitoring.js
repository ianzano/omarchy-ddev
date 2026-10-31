.pragma library

// All display instances share project state and emit one settled notification.
var states = ({})
var projects = ({})
var initialized = ({})
var dirty = ({})
var pendingAt = ({})
var eventVersion = 0
var operations = ({})
var awaitingInventory = ({})
var stopped = ({})
var sawStoppedStatus = ({})

function key(project, service) { return project + "\n" + service }

function markDirty(name, reset) {
    if (!dirty[name] || reset) pendingAt[name] = Date.now()
    dirty[name] = true
}

function register(list) {
    for (var i = 0; i < list.length; i++) {
        var entry = list[i]
        var name = typeof entry === "string" ? entry : entry.name
        if (stopped[name] && typeof entry !== "string") {
            if (entry.status !== "running") sawStoppedStatus[name] = true
            else if (sawStoppedStatus[name]) { delete stopped[name]; delete sawStoppedStatus[name] }
        }
        if (projects[name] === undefined)
            projects[name] = typeof entry === "string" ? "unknown" : entry.status === "running" ? "running" : "stopped"
    }
}

function summary(name) {
    var entries = Object.keys(states).map(k => states[k]).filter(c => c.project === name)
    var alive = entries.filter(c => c.state === "running" || c.state === "paused" || c.state === "restarting")
    if (!alive.length) return {state: "stopped", affected: []}
    var bad = entries.filter(c => c.state !== "paused" && (c.health === "unhealthy" || c.state === "exited" || c.state === "dead" || c.state === "missing"))
    if (bad.length) return {state: "unhealthy", affected: bad.map(c => c.service)}
    if (alive.some(c => c.state === "restarting" || c.health === "starting")) return {state: "starting", affected: []}
    return {state: "running", affected: []}
}

function inventory(containers, announce, registered) {
    register(registered)
    var names = registered.map(p => typeof p === "string" ? p : p.name)
    var found = ({})
    // Replace pre-operation observations with this fresh snapshot.
    Object.keys(awaitingInventory).forEach(name => {
        Object.keys(states).forEach(identity => { if (states[identity].project === name) delete states[identity] })
    })
    for (var i = 0; i < containers.length; i++) {
        var container = containers[i]
        var identity = key(container.project, container.service)
        found[identity] = true
        if (stopped[container.project]) continue
        states[identity] = Object.assign({}, container)
    }
    var identities = Object.keys(states)
    for (var j = 0; j < identities.length; j++) {
        var name = identities[j]
        if (names.indexOf(states[name].project) >= 0 && !found[name])
            states[name] = Object.assign({}, states[name], {state: "missing", health: ""})
    }
    for (var n = 0; n < names.length; n++) {
        var project = names[n]
        if (stopped[project]) { projects[project] = "stopped"; delete dirty[project]; continue }
        delete awaitingInventory[project]
        if (!initialized[project] && !dirty[project]) projects[project] = summary(project).state
        else markDirty(project, false)
        initialized[project] = true
    }
    return []
}

function event(event, announce, registered) {
    eventVersion++
    register(registered)
    var identity = key(event.project, event.service)
    var previous = states[identity] || {}
    // Health messages cannot resurrect exited containers or a completed stop.
    if (stopped[event.project] && event.action !== "start") return []
    if (previous.id && event.id && previous.id !== event.id && event.action !== "start") return []
    if (event.action.indexOf("health_status:") === 0 && ["exited", "dead", "missing"].indexOf(previous.state) >= 0) return []
    if (event.action === "start") { delete stopped[event.project]; delete sawStoppedStatus[event.project] }
    var state = event.action === "die" ? "exited" : event.action === "start" ? "running" : previous.state || "running"
    var health = event.action === "start" ? "starting" : event.action === "die" ? "" : previous.health || ""
    if (event.action === "health_status: unhealthy") health = "unhealthy"
    if (event.action === "health_status: healthy") health = "healthy"
    states[identity] = {project: event.project, service: event.service, id: event.id, state: state, health: health}
    markDirty(event.project, true)
    return []
}

function beginning(name, action) {
    if (["start", "restart", "stop"].indexOf(action) < 0) return
    operations[name] = action
    if (action !== "stop") { delete stopped[name]; delete sawStoppedStatus[name] }
    delete dirty[name]
    delete pendingAt[name]
}

function notification(name, kind, affected) {
    return {kind: kind, project: name, detail: (affected || []).join(", "), title: ({started: "Project started", restarted: "Project restarted", stopped: "Project stopped", unhealthy: "Project needs attention", recovered: "Project healthy again"})[kind]}
}

function completed(name, action, success) {
    if (["start", "restart", "stop"].indexOf(action) < 0) return []
    delete operations[name]
    if (!success) return []
    var wasStopped = projects[name] === "stopped"
    projects[name] = action === "stop" ? "stopped" : "running"
    initialized[name] = true
    delete dirty[name]
    delete pendingAt[name]
    if (action === "stop") {
        stopped[name] = true
        sawStoppedStatus[name] = false
        delete awaitingInventory[name]
        Object.keys(states).forEach(identity => {
            if (states[identity].project === name) states[identity] = Object.assign({}, states[identity], {state: "missing", health: ""})
        })
    } else {
        awaitingInventory[name] = true
    }
    // Invalidate inventory reads launched before command completion.
    eventVersion++
    if (action === "stop" && wasStopped) return []
    return [notification(name, action === "stop" ? "stopped" : action === "restart" ? "restarted" : "started")]
}

function flush(blocked, now) {
    var currentTime = now === undefined ? Date.now() : now
    var alerts = []
    var names = Object.keys(dirty)
    for (var i = 0; i < names.length; i++) {
        var name = names[i]
        if (blocked.indexOf(name) >= 0 || operations[name] || awaitingInventory[name] || stopped[name] || currentTime - pendingAt[name] < 2000) continue
        var current = summary(name)
        if (current.state === "starting") continue
        var old = projects[name]
        var kind = (current.state === "unhealthy" && old !== "unhealthy" ? "unhealthy" :
            current.state === "stopped" && old !== "stopped" && old !== "unknown" ? "stopped" :
            current.state === "running" && old === "unhealthy" ? "recovered" :
            current.state === "running" && old !== "running" ? "started" : "")
        projects[name] = current.state
        delete dirty[name]
        delete pendingAt[name]
        if (kind) alerts.push(notification(name, kind, current.affected))
    }
    return alerts
}
