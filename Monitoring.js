.pragma library

// All display instances share project state and emit one settled notification.
var states = ({})
var projects = ({})
var initialized = ({})
var dirty = ({})
var forced = ({})
var pendingAt = ({})
var eventVersion = 0
var startupUntil = ({})
var warmingUntil = ({})
var startupGraceMs = 60000

function key(project, service) { return project + "\n" + service }

function markDirty(name, reset) {
    if (!dirty[name] || reset) pendingAt[name] = Date.now()
    dirty[name] = true
}

function register(list) {
    for (var i = 0; i < list.length; i++) {
        var entry = list[i]
        var name = typeof entry === "string" ? entry : entry.name
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
    for (var i = 0; i < containers.length; i++) {
        var container = containers[i]
        var identity = key(container.project, container.service)
        found[identity] = true
        var previous = states[identity]
        if (container.state === "running" && (container.health === "starting" || (previous && (previous.id !== container.id || ["exited", "dead", "missing"].indexOf(previous.state) >= 0))) && !warmingUntil[identity])
            warmingUntil[identity] = Date.now() + startupGraceMs
        if (container.health === "healthy") delete warmingUntil[identity]
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
    // Old containers can emit die/health events after their replacement starts.
    if (previous.id && event.id && previous.id !== event.id && event.action !== "start") return []
    if (event.action === "start") {
        if (!warmingUntil[identity]) warmingUntil[identity] = Date.now() + startupGraceMs
        if ((projects[event.project] === "stopped" || projects[event.project] === "unknown") && !startupUntil[event.project])
            startupUntil[event.project] = Date.now() + startupGraceMs
    }
    if (event.action === "health_status: healthy") delete warmingUntil[identity]
    var state = event.action === "die" ? "exited" : "running"
    var health = event.action === "start" ? "starting" : previous.health || ""
    if (event.action === "health_status: unhealthy") health = "unhealthy"
    if (event.action === "health_status: healthy") health = "healthy"
    states[identity] = {project: event.project, service: event.service, id: event.id, state: state, health: health}
    markDirty(event.project, true)
    return []
}

function beginning(name, action) {
    if (action === "start" || action === "restart") startupUntil[name] = Date.now() + startupGraceMs
}

function completed(name, action, success) {
    if (["start", "restart", "stop"].indexOf(action) < 0) return
    if (!success) { delete startupUntil[name]; return }
    markDirty(name, true)
    if (action === "start" || action === "restart") {
        forced[name] = action === "restart" ? "restarted" : "started"
        startupUntil[name] = Date.now() + startupGraceMs
    }
    if (action === "stop") {
        delete startupUntil[name]
        var identities = Object.keys(states)
        for (var i = 0; i < identities.length; i++)
            if (states[identities[i]].project === name) {
                states[identities[i]].state = "missing"
                delete warmingUntil[identities[i]]
            }
    }
}

function flush(blocked, now) {
    var currentTime = now === undefined ? Date.now() : now
    var alerts = []
    var names = Object.keys(dirty)
    for (var i = 0; i < names.length; i++) {
        var name = names[i]
        if (blocked.indexOf(name) >= 0 || currentTime - pendingAt[name] < 2000) continue
        var current = summary(name)
        if (current.state === "starting") continue
        if (forced[name] && current.state === "stopped") {
            if (currentTime < (startupUntil[name] || 0)) continue
            current = {state: "unhealthy", affected: Object.keys(states).map(identity => states[identity]).filter(c => c.project === name).map(c => c.service)}
        }
        if (current.state === "unhealthy" && current.affected.length && current.affected.every(service =>
                currentTime < Math.max(startupUntil[name] || 0, warmingUntil[key(name, service)] || 0))) continue
        var old = projects[name]
        var kind = (current.state === "running" ? forced[name] : "") || (current.state === "unhealthy" && old !== "unhealthy" ? "unhealthy" :
            current.state === "stopped" && old !== "stopped" && old !== "unknown" ? "stopped" :
            current.state === "running" && old === "unhealthy" ? "recovered" :
            current.state === "running" && old !== "running" ? "started" : "")
        projects[name] = current.state
        if (current.state !== "starting") delete startupUntil[name]
        if (current.state === "stopped") {
            Object.keys(warmingUntil).forEach(identity => { if (states[identity] && states[identity].project === name) delete warmingUntil[identity] })
        }
        delete dirty[name]
        delete pendingAt[name]
        delete forced[name]
        if (kind) alerts.push({kind: kind, project: name, detail: current.affected.join(", "), title: ({started: "Project started", restarted: "Project restarted", stopped: "Project stopped", unhealthy: "Project needs attention", recovered: "Project healthy again"})[kind]})
    }
    return alerts
}
