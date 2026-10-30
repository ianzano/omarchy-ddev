.pragma library

// Shared by every monitor's widget: transitions notify once across displays.
var states = ({})
var eventVersion = 0

function key(project, service) { return project + "\n" + service }

function transition(container, announce, event) {
    var identity = key(container.project, container.service)
    var old = states[identity]
    var next = {project: container.project, service: container.service, id: container.id,
        state: container.state, health: container.health || ""}
    states[identity] = next
    if (!announce || (!old && !event)) return []
    var previous = old || {state: "unknown", health: "", id: ""}
    var alive = next.state === "running" || next.state === "restarting"
    var wasAlive = previous.state === "running" || previous.state === "restarting"
    var result = []
    if ((next.state === "exited" || next.state === "dead" || next.state === "missing") && (wasAlive || (!old && event)))
        result.push({kind: "stopped", title: "Container stopped", project: next.project, service: next.service})
    if (alive && previous.state !== "paused" && (!wasAlive || (previous.id && previous.id !== next.id)))
        result.push({kind: "started", title: "Container started", project: next.project, service: next.service})
    if (alive && next.health === "unhealthy" && previous.health !== "unhealthy")
        result.push({kind: "unhealthy", title: "Container unhealthy", project: next.project, service: next.service})
    if (alive && next.health === "healthy" && previous.health === "unhealthy")
        result.push({kind: "recovered", title: "Container healthy again", project: next.project, service: next.service})
    return result
}

function inventory(containers, announce, projects) {
    var found = ({})
    var alerts = []
    for (var i = 0; i < containers.length; i++) {
        var container = containers[i]
        found[key(container.project, container.service)] = true
        alerts = alerts.concat(transition(container, announce, false))
    }
    var identities = Object.keys(states)
    for (var j = 0; j < identities.length; j++) {
        var name = identities[j]
        if (projects && projects.indexOf(states[name].project) < 0) continue
        if (!found[name] && states[name].state !== "missing") {
            var missing = Object.assign({}, states[name], {state: "missing", health: ""})
            alerts = alerts.concat(transition(missing, announce, false))
        }
    }
    return alerts
}

function event(event, announce) {
    eventVersion++
    var previous = states[key(event.project, event.service)] || {}
    var state = event.action === "die" ? "exited" : "running"
    var health = event.action === "start" ? "starting" : previous.health || ""
    if (event.action === "health_status: unhealthy") health = "unhealthy"
    if (event.action === "health_status: healthy") health = "healthy"
    return transition({project: event.project, service: event.service, id: event.id, state: state, health: health}, announce, true)
}
