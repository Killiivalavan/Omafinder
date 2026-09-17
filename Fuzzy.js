// Fuzzy path matching — ports fzf scoring essentials.
// No content search, only path/name. Hidden files included if requested downstream.
.pragma library

function normalize(str) {
    return String(str || "").toLowerCase()
}

// Score bonus for consecutive matches, start-of-string, after slash/dot/underscore/dash.
function fuzzyScore(pattern, text) {
    var p = normalize(pattern)
    var t = normalize(text)
    if (!p) return 0
    if (!t) return -1

    var pLen = p.length
    var tLen = t.length

    var pIdx = 0
    var tIdx = 0
    var score = 0
    var consecutive = 0
    var firstMatchIdx = -1

    while (pIdx < pLen && tIdx < tLen) {
        if (p.charAt(pIdx) === t.charAt(tIdx)) {
            if (firstMatchIdx === -1) firstMatchIdx = tIdx
            consecutive += 1
            // bonus for consecutive
            score += 10 + consecutive * 5
            // bonus for word boundaries
            if (tIdx === 0) score += 10
            else {
                var prev = t.charAt(tIdx - 1)
                if (prev === '/' || prev === '\\' || prev === '_' || prev === '-' || prev === '.' || prev === ' ') score += 8
            }
            // bonus if match is at filename start (after last slash)
            pIdx += 1
        } else {
            if (consecutive > 0) consecutive = 0
            else score -= 1 // small penalty for skipping
        }
        tIdx += 1
    }

    if (pIdx !== pLen) return -1 // not all pattern chars matched

    // Prefer shorter paths and earlier matches
    score -= tLen * 0.1
    if (firstMatchIdx > 0) score -= firstMatchIdx * 0.5
    // Prefer filename match over deep path match
    var slashIdx = t.lastIndexOf('/')
    if (slashIdx !== -1) {
        var filename = t.slice(slashIdx + 1)
        if (filename.indexOf(p) !== -1) score += 15
        else {
            // if pattern matches inside filename fuzzily, boost
            var fscore = fuzzyScoreSimple(p, filename)
            if (fscore >= 0) score += 10
        }
    }
    return score
}

function fuzzyScoreSimple(pattern, text) {
    var p = normalize(pattern)
    var t = normalize(text)
    var pi = 0, ti = 0
    while (pi < p.length && ti < t.length) {
        if (p.charAt(pi) === t.charAt(ti)) pi++
        ti++
    }
    return pi === p.length ? 1 : -1
}

function fuzzyMatch(pattern, text) {
    return fuzzyScore(pattern, text) >= 0
}

// Expand ~ and $HOME, resolve relative.
function expandPath(input, home) {
    var s = String(input || "").trim()
    if (!s) return ""
    if (s === "~") return home
    if (s.indexOf("~/") === 0) return home + s.slice(1)
    if (s.indexOf("$HOME/") === 0) return home + s.slice(5)
    if (s.indexOf("$HOME") === 0) return home + s.slice(5)
    return s
}

function isPathLike(input) {
    var s = String(input || "")
    if (!s) return false
    if (s.charAt(0) === '/' || s.charAt(0) === '~') return true
    if (s.indexOf('/') !== -1) return true
    if (s === "." || s === ".." || s.indexOf("./") === 0 || s.indexOf("../") === 0) return true
    return false
}

function dirname(path) {
    var s = String(path || "")
    if (!s) return "."
    // trim trailing slash
    if (s.length > 1 && s.charAt(s.length - 1) === '/') s = s.slice(0, -1)
    var idx = s.lastIndexOf('/')
    if (idx === -1) return "."
    if (idx === 0) return "/"
    return s.slice(0, idx)
}

function basename(path) {
    var s = String(path || "")
    if (s.length > 1 && s.charAt(s.length - 1) === '/') s = s.slice(0, -1)
    var idx = s.lastIndexOf('/')
    return idx === -1 ? s : s.slice(idx + 1)
}

function scoreAndSort(candidates, query, limit) {
    var q = String(query || "").trim()
    if (!q) return candidates.slice(0, limit || 100)
    var scored = []
    for (var i = 0; i < candidates.length; i++) {
        var c = candidates[i]
        var text = (c.path || c) // support string or object
        var s = fuzzyScore(q, text)
        if (s >= 0) scored.push({ item: c, score: s, text: text })
    }
    scored.sort(function(a,b){
        if (b.score !== a.score) return b.score - a.score
        if (a.text.length !== b.text.length) return a.text.length - b.text.length
        return a.text.localeCompare(b.text)
    })
    var out = []
    var n = Math.min(scored.length, limit || 100)
    for (var j=0;j<n;j++) out.push(scored[j].item)
    return out
}
